defmodule Foreman.Secrets do
  @moduledoc """
  Secrets at four scopes, resolved in order of increasing priority:

  1. **owner** - the GitHub org or user account (admins)
  2. **repo** (admins)
  3. **user** - all of a user's environments, or only selected repos (the user)
  4. **environment** - one environment (its owner)

  Values are encrypted at rest and write-only: the UI can replace or
  delete a secret but never read it back. Every change is audited (names
  only) and pushed to the running environments it affects.
  """
  import Ecto.Query

  alias Foreman.Accounts.User
  alias Foreman.Environments.Environment
  alias Foreman.Repos.{Owner, Repo}
  alias Foreman.Secrets.Secret
  alias Foreman.{Audit, Scope}

  # -- scopes and authorization -----------------------------------------------------

  def scope_key("owner", %Owner{id: id}), do: "owner:" <> id
  def scope_key("repo", %Repo{id: id}), do: "repo:" <> id
  def scope_key("user", %User{id: id}), do: "user:" <> id
  def scope_key("environment", %Environment{id: id}), do: "environment:" <> id

  def authorize(%Scope{} = scope, scope_name, subject) do
    allowed =
      case {scope_name, subject} do
        {"owner", %Owner{}} ->
          Scope.admin?(scope)

        {"repo", %Repo{}} ->
          Scope.admin?(scope)

        {"user", %User{id: id}} ->
          Scope.user_id(scope) == id

        {"environment", %Environment{user_id: id}} ->
          Scope.user_id(scope) == id or Scope.admin?(scope)

        _ ->
          false
      end

    if allowed, do: :ok, else: {:error, :unauthorized}
  end

  # -- reading (names only) -------------------------------------------------------

  @doc "The secrets at a scope, without values (the value field is cleared)."
  def list_secrets(%Scope{} = scope, scope_name, subject) do
    with :ok <- authorize(scope, scope_name, subject) do
      secrets =
        from(s in Secret,
          where: s.scope_key == ^scope_key(scope_name, subject),
          order_by: s.name,
          preload: :updated_by
        )
        |> Foreman.Repo.all()
        |> Enum.map(&%{&1 | value: nil})

      {:ok, secrets}
    end
  end

  def change_secret(attrs \\ %{}), do: Secret.changeset(%Secret{}, attrs)

  # -- writing -----------------------------------------------------------------------

  @doc """
  Creates a secret, or replaces the value of the one with the same name at
  the same scope.
  """
  def put_secret(%Scope{} = scope, scope_name, subject, attrs) do
    with :ok <- authorize(scope, scope_name, subject) do
      key = scope_key(scope_name, subject)
      name = attrs["name"] || attrs[:name]
      existing = name && Foreman.Repo.get_by(Secret, scope_key: key, name: name)

      secret =
        existing ||
          %Secret{scope: scope_name, scope_key: key}
          |> Map.merge(subject_fields(scope_name, subject))

      changeset =
        secret
        |> Secret.changeset(Map.update(stringify(attrs), "repo_ids", [], &List.wrap/1))
        |> Ecto.Changeset.put_change(:updated_by_id, Scope.user_id(scope))

      with {:ok, saved} <- Foreman.Repo.insert_or_update(changeset) do
        Audit.log(scope, if(existing, do: "secret.update", else: "secret.create"), saved, %{
          "scope" => key,
          "name" => saved.name
        })

        Foreman.Environments.secrets_changed(affected_environment_ids(scope_name, subject))
        {:ok, %{saved | value: nil}}
      end
    end
  end

  def delete_secret(%Scope{} = scope, scope_name, subject, name) do
    with :ok <- authorize(scope, scope_name, subject),
         %Secret{} = secret <-
           Foreman.Repo.get_by(Secret, scope_key: scope_key(scope_name, subject), name: name) do
      Foreman.Repo.delete!(secret)
      Audit.log(scope, "secret.delete", secret, %{"scope" => secret.scope_key, "name" => name})
      Foreman.Environments.secrets_changed(affected_environment_ids(scope_name, subject))
      :ok
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp subject_fields("owner", %Owner{id: id}), do: %{owner_id: id}
  defp subject_fields("repo", %Repo{id: id}), do: %{repo_id: id}
  defp subject_fields("user", %User{id: id}), do: %{user_id: id}
  defp subject_fields("environment", %Environment{id: id}), do: %{environment_id: id}

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp affected_environment_ids(scope_name, subject) do
    base = from e in Environment, where: is_nil(e.destroyed_at), select: e.id

    query =
      case {scope_name, subject} do
        {"owner", %Owner{id: id}} ->
          from e in base, join: r in assoc(e, :repo), where: r.owner_id == ^id

        {"repo", %Repo{id: id}} ->
          from e in base, where: e.repo_id == ^id

        {"user", %User{id: id}} ->
          from e in base, where: e.user_id == ^id

        {"environment", %Environment{id: id}} ->
          from e in base, where: e.id == ^id
      end

    Foreman.Repo.all(query)
  end

  # -- resolution --------------------------------------------------------------------

  @doc "The secrets an environment gets, name => value, with later scopes winning."
  def resolve(%Environment{} = env) do
    env = Foreman.Repo.preload(env, :repo)

    keys = [
      "owner:" <> env.repo.owner_id,
      "repo:" <> env.repo_id,
      "user:" <> env.user_id,
      "environment:" <> env.id
    ]

    rank = keys |> Enum.with_index() |> Map.new()

    from(s in Secret, where: s.scope_key in ^keys)
    |> Foreman.Repo.all()
    |> Enum.filter(fn s -> s.scope != "user" or s.repo_ids == [] or env.repo_id in s.repo_ids end)
    |> Enum.sort_by(&rank[&1.scope_key])
    |> Enum.reduce(%{}, fn s, acc -> Map.put(acc, s.name, s.value) end)
  end

  @doc """
  A keyed hash of each value, so the control plane can tell which secrets
  changed since an environment last restarted without storing the values
  a second time. Keyed, so a leaked database can't be checked against
  guesses offline.
  """
  def hashes(values) do
    key = hash_key()

    Map.new(values, fn {name, value} ->
      {name,
       Base.encode16(:crypto.mac(:hmac, :sha256, key, name <> <<0>> <> value), case: :lower)}
    end)
  end

  @doc "Names that were added, removed or changed between two hash maps."
  def changed_names(old, new) do
    old = old || %{}
    names = MapSet.union(MapSet.new(Map.keys(old)), MapSet.new(Map.keys(new)))
    names |> Enum.filter(&(old[&1] != new[&1])) |> Enum.sort()
  end

  defp hash_key do
    base = Application.fetch_env!(:foreman, ForemanWeb.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(base, "foreman secret hashes",
      length: 32,
      cache: Plug.Crypto.Keys
    )
  end

  # -- rendering -----------------------------------------------------------------------

  @doc """
  The `secrets.env` file: one `export NAME='value'` per secret, single
  quoted so the shell takes values literally.
  """
  def render_env_file(values) do
    lines =
      values
      |> Enum.sort()
      |> Enum.map(fn {name, value} ->
        "export #{name}='#{String.replace(value, "'", "'\\''")}'\n"
      end)

    IO.iodata_to_binary([
      "# Managed by Foreman. New shells pick up changes; restart processes to apply them.\n"
      | lines
    ])
  end
end
