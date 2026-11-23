defmodule Foreman.OAuth.ServiceAccounts do
  @moduledoc "Installation identities and their explicitly approved workload resources."
  import Ecto.Query

  alias Foreman.{Accounts, Audit, OAuth, Repo, Scope}
  alias Foreman.Accounts.User
  alias Foreman.Boxes.Box
  alias Foreman.OAuth.{Client, Grant, GrantRepository, Principal, Scopes, Store, Token}
  alias Foreman.PublicAPI.{Access, RepositoryAccess}
  alias Foreman.Repos.Repo, as: Repository
  alias Foreman.Secrets.Secret

  def principal_for_user(user_id) do
    with {:ok, id} <- Ecto.UUID.cast(user_id),
         grant_id when is_binary(grant_id) <-
           Repo.one(
             from g in OAuth.live_grants(),
               join: u in assoc(g, :user),
               where: g.user_id == ^id and u.service_account,
               select: g.id
           ) do
      OAuth.authorize_grant(grant_id)
    else
      _ -> :error
    end
  end

  def repo_ids(%Principal{kind: :service_account} = principal) do
    Repo.all(from r in Access.repos(principal), select: r.id)
  end

  def repo_ids(_), do: []

  def repo_ids(%Principal{kind: :service_account} = principal, primary_repo_id)
      when is_binary(primary_repo_id) do
    Repo.all(from r in Access.service_workload_repos(principal, primary_repo_id), select: r.id)
  end

  def repo_ids(_, _), do: []
  def box_ids(principal), do: grant_field(principal, :box_ids) || []
  def secret_ids(principal), do: grant_field(principal, :secret_ids) || []
  def network_policy(principal), do: grant_field(principal, :network_policy)

  defp grant_field(
         %Principal{kind: :service_account, user: user, grant_id: id, client_id: client},
         key
       ) do
    Repo.one(
      from g in OAuth.live_grants(),
        where: g.id == ^id and g.user_id == ^user.id and g.client_id == ^client,
        select: field(g, ^key)
    )
  end

  defp grant_field(_, _), do: nil

  def inventory(scope) do
    admin_transaction(scope, fn _actor ->
      {:ok, %{clients: clients(), installations: installations(), choices: choices()}}
    end)
  end

  def clients(%Scope{} = scope), do: admin_read(scope, &clients/0, [])
  def installations(%Scope{} = scope), do: admin_read(scope, &installations/0, [])
  def choices(%Scope{} = scope), do: admin_read(scope, &choices/0, nil)

  defp admin_read(scope, query, fallback) do
    case admin_transaction(scope, fn _actor -> {:ok, query.()} end) do
      {:ok, result} -> result
      {:error, :unauthorized} -> fallback
    end
  end

  defp clients, do: Repo.all(from c in Client, order_by: c.name)

  defp installations do
    Repo.all(
      from g in Grant,
        join: c in assoc(g, :client),
        where: c.kind == "service",
        preload: [client: c, user: []],
        order_by: c.name
    )
  end

  defp choices do
    %{
      repos:
        Repo.all(
          from r in grantable_repos(),
            order_by: r.full_name,
            select: {r.id, r.full_name}
        ),
      boxes:
        Repo.all(
          from b in Box, where: is_nil(b.revoked_at), order_by: b.name, select: {b.id, b.name}
        ),
      secrets:
        Repo.all(
          from s in Secret,
            where: s.scope in ["owner", "repo"],
            order_by: s.name,
            select: {s.id, s.name, s.scope_key}
        )
    }
  end

  def register(scope, kind, attrs) when kind in ["service", "public"] do
    name = attrs["name"]

    admin_transaction(scope, fn actor ->
      if is_binary(name) and String.trim(name) != "" and String.length(name) <= 120 do
        register_client(actor, kind, String.trim(name), attrs)
      else
        {:error, :invalid_name}
      end
    end)
  end

  def register(_, _, _), do: {:error, :invalid_request}

  defp register_client(scope, "public", name, _) do
    client = Repo.insert!(%Client{id: "app-" <> Ecto.UUID.generate(), name: name, kind: "public"})
    Audit.log(scope, "oauth.client.register", client)
    {:ok, %{client: client}}
  end

  defp register_client(scope, "service", name, attrs) do
    with {:ok, scopes} <- Store.validate_scopes(attrs["scopes"], Scopes.all()),
         {:ok, ids, repositories} <- resources(attrs),
         {:ok, tags} <- tags(attrs["tailscale_tags"] || []) do
      id = Ecto.UUID.generate()

      user =
        Repo.insert!(%User{id: id, login: "service:" <> id, name: name, service_account: true})

      secret = Store.random_secret()

      client =
        Repo.insert!(%Client{
          id: "svc-" <> id,
          name: name,
          kind: "service",
          secret_hash: Store.digest(secret)
        })

      policy = %{"tailscale_tags" => Enum.uniq(["tag:foreman-svc-" <> id | tags])}

      grant =
        Repo.insert!(
          struct!(
            %Grant{
              user_id: user.id,
              client_id: client.id,
              scopes: scopes,
              network_policy: policy
            },
            ids
          )
        )

      Repo.insert_all(GrantRepository, Enum.map(repositories, &Map.put(&1, :grant_id, grant.id)))

      Audit.log(scope, "oauth.installation.create", grant, %{
        "client_id" => client.id,
        "user_id" => user.id
      })

      {:ok, %{client: client, grant: grant, secret: secret}}
    end
  end

  defp resources(attrs) do
    with {:ok, repos} <-
           selected(
             attrs["repo_ids"],
             from(r in grantable_repos(), select: %{repo_id: r.id, github_id: r.github_id})
           ),
         {:ok, boxes} <-
           selected(attrs["box_ids"], from(b in Box, where: is_nil(b.revoked_at), select: b.id)),
         {:ok, secrets} <-
           selected(
             attrs["secret_ids"],
             from(s in Secret, where: s.scope in ["owner", "repo"], select: s.id)
           ) do
      {:ok, %{repo_ids: Enum.map(repos, & &1.repo_id), box_ids: boxes, secret_ids: secrets},
       repos}
    end
  end

  defp grantable_repos do
    RepositoryAccess.grantable(from r in Repository, where: is_nil(r.removed_at))
  end

  defp selected(nil, _), do: {:ok, []}

  defp selected(ids, query) when is_list(ids) do
    if Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      available = Repo.all(from r in query, where: r.id in ^ids)

      if MapSet.size(MapSet.new(ids)) == length(available),
        do: {:ok, available},
        else: {:error, :invalid_resource}
    else
      {:error, :invalid_resource}
    end
  end

  defp selected(_, _), do: {:error, :invalid_resource}

  defp tags(tags) when is_binary(tags), do: tags(String.split(tags, [",", " ", "\n"], trim: true))

  defp tags(tags) when is_list(tags) do
    if Enum.all?(
         tags,
         &(is_binary(&1) and Regex.match?(~r/\Atag:[a-zA-Z0-9][a-zA-Z0-9-]{0,62}\z/, &1))
       ), do: {:ok, tags}, else: {:error, :invalid_network_policy}
  end

  defp tags(_), do: {:error, :invalid_network_policy}

  defp admin_transaction(scope, mutate) do
    Repo.transact(fn ->
      with {:ok, actor} <- Accounts.lock_admin(scope), do: mutate.(actor)
    end)
  end

  def rotate(scope, client_id) do
    admin_transaction(scope, fn actor ->
      case locked_client(client_id) do
        %Client{kind: "service", disabled_at: nil} = client ->
          secret = Store.random_secret()
          client = Repo.update!(Ecto.Changeset.change(client, secret_hash: Store.digest(secret)))
          grant = Repo.get_by!(Grant, client_id: client.id)
          Repo.delete_all(from t in Token, where: t.grant_id == ^grant.id)
          Audit.log(actor, "oauth.installation.rotate", grant, %{"client_id" => client.id})
          {:ok, %{client: client, secret: secret}}

        _ ->
          {:error, :invalid_client}
      end
    end)
  end

  def disable(scope, client_id) do
    admin_transaction(scope, fn actor -> disable_client(actor, locked_client(client_id)) end)
  end

  defp disable_client(scope, %Client{id: id} = client) when id != "foreman-cli" do
    now = DateTime.utc_now()
    Repo.update!(Ecto.Changeset.change(client, disabled_at: now, secret_hash: nil))

    if client.kind == "service" do
      grant = Repo.get_by!(Grant, client_id: id)
      Repo.update_all(from(u in User, where: u.id == ^grant.user_id), set: [disabled_at: now])
    end

    Repo.update_all(from(g in Grant, where: g.client_id == ^id and is_nil(g.revoked_at)),
      set: [revoked_at: now]
    )

    Audit.log(scope, "oauth.client.disable", client)
    {:ok, :disabled}
  end

  defp disable_client(_, _), do: {:error, :invalid_client}

  defp locked_client(id), do: Repo.one_for_update(from c in Client, where: c.id == ^id)

  def with_credentials(id, secret, action) when is_binary(id) and is_binary(secret) do
    Repo.transact(fn ->
      with %Client{kind: "service", disabled_at: nil, secret_hash: digest} = client <-
             locked_client(id),
           true <- Plug.Crypto.secure_compare(digest, Store.digest(secret)) do
        action.(client)
      else
        _ -> {:error, :invalid_client}
      end
    end)
  end

  def issue(%Client{kind: "service"} = client, requested) do
    with %Grant{} = grant <- Repo.get_by(Grant, client_id: client.id),
         {:ok, _} <- OAuth.authorize_grant(grant.id),
         {:ok, scopes} <- OAuth.optional_scopes(requested, grant.scopes) do
      {:ok, OAuth.issue(grant, scopes, :service_account)}
    else
      {:error, :invalid_scope} = error -> error
      _ -> {:error, :invalid_client}
    end
  end
end
