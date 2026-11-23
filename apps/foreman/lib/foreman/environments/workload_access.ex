defmodule Foreman.Environments.WorkloadAccess do
  @moduledoc """
  Checks the original workload owner and the identity requesting the command.
  A browser administrator's shutdown and a due expiry need no guest files.
  All other work, including reconciliation, needs a live owner.
  """
  import Ecto.Query
  alias Foreman.{Accounts, OAuth, Repo, Repos}
  alias Foreman.OAuth.ServiceAccounts
  alias Foreman.PublicAPI.Access

  @denied {:error, :unauthorized}

  def authorize(op, env, mode \\ :remote)

  def authorize(%{trigger: "expiry", action: action, api_grant_id: nil, user_id: nil}, env, _mode)
      when action in ["stop", "destroy"] and action == env.expiry_action and
             is_nil(env.expiry_consumed_at) and not is_nil(env.expiry_at) do
    if DateTime.compare(env.expiry_at, DateTime.utc_now()) != :gt, do: {:ok, nil}, else: @denied
  end

  def authorize(%{trigger: "expiry"}, _env, _mode), do: @denied

  def authorize(
        %{user_id: nil, api_grant_id: nil} = op,
        %{desired_authority: %{} = intent} = env,
        mode
      ) do
    if intent_applies?(op.action, env.desired_state, intent) do
      # Replay the current request's authority for a system repair. For a file write,
      # an administrator's stop/destroy can never supply workload credentials.
      request = %{
        op
        | user_id: intent["user_id"],
          api_grant_id: intent["grant_id"],
          trigger: intent["trigger"],
          action: intent["action"]
      }

      if request.trigger == "expiry" do
        authorize(request, env, mode)
      else
        authorize_request(request, env, mode)
      end
    else
      @denied
    end
  end

  def authorize(op, env, mode), do: authorize_request(op, env, mode)

  defp intent_applies?(action, "running", %{"action" => source})
       when source in ~w(create start rebuild pull_rebuild restart_all restart_affected),
       do: action in ~w(create start secrets_write)

  defp intent_applies?("secrets_write", "suspended", %{"action" => "suspend"}), do: true
  defp intent_applies?("stop", "stopped", %{"action" => "stop"}), do: true
  defp intent_applies?("destroy", "destroyed", %{"action" => "destroy"}), do: true
  defp intent_applies?("suspend", "suspended", %{"action" => "suspend"}), do: true
  defp intent_applies?(_, _, _), do: false

  defp authorize_request(op, env, mode) do
    with {:ok, actor} <- actor(op, env, mode) do
      if authorized_shutdown?(op, actor) do
        {:ok, nil}
      else
        with {:ok, origin} <- owner(op, env, actor, mode),
             true <- launchable?(op, env, origin || actor),
             :ok <- automatic_scope(op, origin),
             {:ok, policy} <- policy(origin || actor, env, mode),
             true <- still_active?(actor) and still_active?(origin) do
          {:ok, policy}
        else
          false -> @denied
          other -> other
        end
      end
    end
  rescue
    Access.Unavailable -> :retry
  end

  defp launchable?(%{action: action, command: command}, %{created_once: false} = env, %{
         grant_id: _
       })
       when action == "create" or command == "env.create" do
    Repo.exists?(
      from r in Repos.Repo,
        where: r.id == ^env.repo_id and not r.archived and not is_nil(r.devcontainer_path)
    )
  end

  defp launchable?(_op, _env, _principal), do: true

  def automatic_active?(
        %{desired_authority: %{"action" => action, "user_id" => id, "grant_id" => nil}} = env,
        action
      )
      when action in ["stop", "destroy"] and not is_nil(id) do
    actor = Accounts.get_user(id)
    owner_active?(env) or (eligible?(actor) and actor.role == "admin")
  end

  def automatic_active?(env, _action), do: owner_active?(env)

  defp owner_active?(env) do
    case Accounts.get_user(env.user_id) do
      %{service_account: true} ->
        match?({:ok, _}, ServiceAccounts.principal_for_user(env.user_id))

      user ->
        eligible?(user) and active_grant?(env.workload_grant_id || env.api_grant_id, env.user_id)
    end
  end

  defp still_active?(nil), do: true
  defp still_active?(%{grant_id: id, user: user}), do: active_grant?(id, user.id)
  defp still_active?(%{user: user}), do: eligible?(Accounts.get_user(user.id))

  defp active_grant?(nil, _), do: true

  defp active_grant?(id, user_id) do
    case OAuth.authorize_grant(id) do
      {:ok, principal} -> principal.user.id == user_id
      :error -> false
    end
  end

  defp eligible?(%{disabled_at: nil, workload_access_revoked_at: nil} = user),
    do: user.service_account or Accounts.access(user) != :denied

  defp eligible?(_), do: false

  defp actor(%{api_grant_id: id} = op, env, mode) when not is_nil(id) do
    with {:ok, principal} <- grant(id, op.user_id, env, mode),
         true <- scope?(principal, op.action),
         true <-
           op.action != "create" or is_nil(env.expiry_action) or
             scope?(principal, env.expiry_action) do
      {:ok, principal}
    else
      _ -> @denied
    end
  end

  defp actor(%{user_id: nil}, _env, _mode), do: {:ok, nil}

  defp actor(op, env, _mode) do
    user = Accounts.get_user(op.user_id)

    if eligible?(user) and (user.id == env.user_id or user.role == "admin") and
         (op.action != "connect" or user.id == env.user_id),
       do: {:ok, %{kind: :browser, user: user}},
       else: @denied
  end

  defp authorized_shutdown?(%{action: action}, %{kind: :browser, user: %{role: "admin"}}),
    do: action in ["stop", "destroy"]

  defp authorized_shutdown?(%{action: action}, %{kind: kind})
       when kind in [:user, :service_account],
       do: action in ["stop", "destroy"]

  defp authorized_shutdown?(_op, _actor), do: false

  # An independently authorized personal start may take over an existing workspace.
  # The source of every request and the creator's grant remain on their original rows.
  defp owner(%{action: action}, env, %{kind: :user} = actor, _mode)
       when action in ["start", "secrets_write"] and actor.user.id == env.user_id,
       do: {:ok, actor}

  defp owner(_op, %{workload_grant_id: id} = env, actor, mode) when not is_nil(id),
    do: workload_owner(id, "start", env, actor, mode)

  defp owner(_op, %{api_grant_id: id} = env, actor, mode) when not is_nil(id),
    do: workload_owner(id, "create", env, actor, mode)

  defp owner(_op, env, _actor, mode) do
    case Accounts.get_user(env.user_id) do
      %{service_account: true} = user ->
        with {:ok, principal} <- ServiceAccounts.principal_for_user(user.id),
             true <- eligible?(user) and visible?(principal, env, mode) do
          {:ok, principal}
        else
          _ -> @denied
        end

      user ->
        if eligible?(user), do: {:ok, nil}, else: @denied
    end
  end

  defp workload_owner(id, action, env, %{grant_id: id} = actor, _mode) do
    if actor.user.id == env.user_id and scope?(actor, action), do: {:ok, actor}, else: @denied
  end

  defp workload_owner(id, action, env, _, mode) do
    with {:ok, principal} <- grant(id, env.user_id, env, mode),
         true <- scope?(principal, action),
         do: {:ok, principal},
         else: (_ -> @denied)
  end

  defp grant(id, user_id, env, mode) do
    with {:ok, principal} <- OAuth.authorize_grant(id),
         true <- principal.user.id == user_id and eligible?(principal.user),
         true <- visible?(principal, env, mode),
         do: {:ok, principal},
         else: (_ -> @denied)
  end

  defp visible?(principal, env, :remote), do: Repo.exists?(Access.environments(principal, env.id))

  defp visible?(%{kind: :service_account} = principal, env, _),
    do: Repo.exists?(Access.environments(principal, env.id))

  defp visible?(principal, env, _delivery) do
    if Foreman.GitHub.configured?() do
      bound_at = env.repo.github_identity_bound_at

      principal.user.id == env.user_id and not is_nil(env.repo.github_id) and
        is_nil(env.repo.removed_at) and
        (is_nil(bound_at) or DateTime.compare(bound_at, env.inserted_at) != :gt) and
        Repo.exists?(from b in Access.boxes(principal), where: b.id == ^env.box_id)
    else
      Repo.exists?(Access.environments(principal, env.id))
    end
  end

  defp automatic_scope(%{user_id: nil, action: action}, %{scopes: _} = origin)
       when action in ["create", "start", "stop", "destroy", "suspend"] do
    if scope?(origin, action), do: :ok, else: @denied
  end

  defp automatic_scope(_op, _origin), do: :ok

  defp scope?(principal, "secrets_write"), do: scope?(principal, "start")

  defp scope?(principal, action) when action in ~w(create start stop destroy),
    do: ("environments:" <> action) in principal.scopes

  defp scope?(_principal, _action), do: false

  defp policy(nil, _env, _mode), do: {:ok, nil}
  defp policy(%{kind: :browser}, _env, _mode), do: {:ok, nil}

  defp policy(principal, env, mode) do
    repo = Repo.preload(env, repo: :owner).repo
    candidates = Repos.extra_repos(repo)

    extras =
      Repo.all(
        from r in Repos.Repo,
          where:
            r.owner_id == ^repo.owner_id and r.name in ^candidates and is_nil(r.removed_at) and
              not r.archived,
          order_by: r.name,
          select: {r.id, r.github_id}
      )

    ids =
      for {id, github_id} <- extras,
          is_integer(github_id),
          approved_repo?(principal, id, github_id, mode),
          do: github_id

    if Foreman.GitHub.configured?() and is_nil(repo.github_id) do
      @denied
    else
      network(%{principal: principal, repository_ids: Enum.uniq([repo.github_id | ids])})
    end
  end

  defp approved_repo?(%{kind: :user}, _id, github_id, {:delivery, ids}), do: github_id in ids

  defp approved_repo?(principal, id, _github_id, _mode),
    do: Repo.exists?(Access.repos(principal, id))

  # The remote membership checks and the credential mint are complete. Serialize the
  # final local mailbox send with disables, grant revocations and box sharing changes.
  # No GitHub or tailnet call is permitted inside this transaction.
  def deliver(op, env, policy, send_command) do
    Repo.transact(fn ->
      lock_row(Foreman.Boxes.Box, env.box_id)
      env = Foreman.Environments.locked_environment(env.id) |> Repo.preload(repo: :owner)
      selected_ids = if policy, do: Enum.reject(policy.repository_ids, &is_nil/1), else: []

      lock_query(
        from r in Repos.Repo, where: r.id == ^env.repo_id or r.github_id in ^selected_ids
      )

      grants =
        [
          op.api_grant_id,
          env.api_grant_id,
          env.workload_grant_id,
          (env.desired_authority || %{})["grant_id"],
          policy && policy.principal.grant_id
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      grant_query = from g in OAuth.Grant, where: g.id in ^grants
      clients = Repo.all(select(grant_query, [g], g.client_id))

      users =
        [env.user_id, op.user_id, (env.desired_authority || %{})["user_id"]]
        |> Enum.reject(&is_nil/1)

      # Admin mutations lock their human actor before a client, then its service
      # identity and grant. Follow the same order for personal and service work.
      lock_query(from u in Accounts.User, where: u.id in ^users and not u.service_account)
      lock_rows(OAuth.Client, clients)
      lock_query(from u in Accounts.User, where: u.id in ^users and u.service_account)
      lock_rows(OAuth.Grant, grants)
      env = Repo.preload(env, :repo, force: true)
      mode = {:delivery, if(policy, do: policy.repository_ids, else: [])}

      case authorize(op, env, mode) do
        {:ok, ^policy} -> {:ok, send_command.(env)}
        {:ok, _changed} -> {:ok, :retry}
        other -> {:ok, other}
      end
    end)
    |> elem(1)
  end

  defp lock_row(schema, id), do: lock_rows(schema, [id])

  defp lock_rows(schema, ids) do
    lock_query(from row in schema, where: row.id in ^ids)
  end

  defp lock_query(query) do
    unless Repo.sqlite?() do
      Repo.all(
        from row in query,
          order_by: row.id,
          select: row.id,
          lock: "FOR SHARE"
      )
    end
  end

  defp network(%{principal: %{kind: :service_account} = principal} = policy) do
    case ServiceAccounts.network_policy(principal) do
      %{"tailscale_tags" => [_ | _] = tags} ->
        if Enum.filter(tags, &ServiceAccounts.identity_tag?/1) == [
             ServiceAccounts.identity_tag(principal.user.id)
           ],
           do:
             {:ok,
              Map.merge(policy, %{tags: tags, secret_ids: ServiceAccounts.secret_ids(principal)})},
           else: @denied

      _ ->
        @denied
    end
  end

  defp network(policy), do: {:ok, policy}
end
