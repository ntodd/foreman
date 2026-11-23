defmodule Foreman.Secrets do
  @moduledoc """
  Secrets at four scopes, resolved in order of increasing priority:

  1. **owner** - the GitHub org or user account (admins)
  2. **repo** (admins)
  3. **user** - all of a user's environments, or only selected repos (the user)
  4. **environment** - one environment (its owner)

  Values are encrypted at rest and write-only: the UI can replace or
  delete a secret but never read it back. Every change is audited (names
  only) and pushed to the running environments it affects. An environment
  secret can be promoted to the repo or to its owner's secrets.
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

  @doc """
  The secrets a scope picks up from the scopes above it, without values:
  an environment's from its owner, repo and user, a repo's from its owner.
  Ordered by scope, then name. A name set at two scopes is listed at both.
  A user's own secrets are listed only to that user, as on their own page,
  so an admin on someone else's environment sees the owner's and repo's.
  """
  def list_inherited_secrets(%Scope{} = scope, scope_name, subject) do
    with :ok <- authorize(scope, scope_name, subject) do
      secrets =
        case {scope_name, subject} do
          {"environment", %Environment{} = env} ->
            [owner, repo, user, _env] = env_secrets(env)
            if Scope.user_id(scope) == env.user_id, do: [owner, repo, user], else: [owner, repo]

          {"repo", %Repo{owner_id: owner_id}} ->
            [secrets_at("owner:" <> owner_id)]

          _ ->
            []
        end

      {:ok, secrets |> Enum.concat() |> Enum.map(&%{&1 | value: nil})}
    end
  end

  defp secrets_at(key) do
    Foreman.Repo.all(from s in Secret, where: s.scope_key == ^key, order_by: s.name)
  end

  def change_secret(attrs \\ %{}), do: Secret.changeset(%Secret{}, attrs)

  # -- writing -----------------------------------------------------------------------

  @doc """
  Creates a secret, or replaces the value of the one with the same name at
  the same scope.
  """
  def put_secret(%Scope{} = scope, scope_name, subject, attrs) do
    with :ok <- authorize(scope, scope_name, subject),
         {:ok, saved} <-
           while_live(subject, fn -> save_secret(scope, scope_name, subject, attrs) end) do
      Foreman.Environments.secrets_changed(affected_environment_ids(scope_name, subject))
      {:ok, saved}
    end
  end

  @doc """
  Sets and removes several secrets at one scope together: every change is
  saved, or none is. `set` is a list of `{name, value}`; `unset` a list of
  names, where one that isn't set is skipped. Environments hear about the
  whole batch once.

  Returns the names set and the names actually removed, or
  `{:error, {:invalid, name, message}}` for the first secret refused.
  `opts[:audit]` is merged into each audit entry, for a caller that acts
  through something worth recording (an API client, say).

  `opts[:recheck]` runs inside the transaction, before anything is
  written, and its error ends the batch: for a caller whose authority
  was established earlier in the request and may have gone since.

  Batches at one scope run one at a time, so two that touch the same
  name can't both find it absent, or both remove it.
  """
  def apply_changes(%Scope{} = scope, scope_name, subject, set, unset, opts \\ []) do
    audit = Keyword.get(opts, :audit, %{})
    recheck = Keyword.get(opts, :recheck, fn -> :ok end)

    # The scope's turn is taken first: a check made while still waiting
    # for it could be out of date by the time the write runs.
    change = fn ->
      serialize(scope_key(scope_name, subject))
      with :ok <- recheck.(), do: change_all(scope, scope_name, subject, set, unset, audit)
    end

    with :ok <- authorize(scope, scope_name, subject),
         {:ok, changed} <- Foreman.Repo.transact(fn -> while_live(subject, change) end) do
      Foreman.Environments.secrets_changed(affected_environment_ids(scope_name, subject))
      {:ok, changed}
    end
  end

  defp change_all(scope, scope_name, subject, set, unset, audit) do
    saved =
      Enum.reduce_while(set, {:ok, []}, fn {name, value}, {:ok, names} ->
        attrs = %{"name" => name, "value" => value}

        case save_secret(scope, scope_name, subject, attrs, audit) do
          {:ok, secret} -> {:cont, {:ok, [secret.name | names]}}
          {:error, changeset} -> {:halt, {:error, {:invalid, name, refusal(changeset)}}}
        end
      end)

    with {:ok, names} <- saved do
      removed = Enum.filter(unset, &remove_secret(scope, scope_name, subject, &1, audit))
      {:ok, %{set: Enum.reverse(names), unset: removed}}
    end
  end

  # SQLite's write transactions already run one at a time. On Postgres a
  # lock on the scope, held to the end of the transaction, does the same.
  defp serialize(key) do
    unless Foreman.Repo.sqlite?() do
      Foreman.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["secrets:" <> key])
    end

    :ok
  end

  defp remove_secret(scope, scope_name, subject, name, audit) do
    key = scope_key(scope_name, subject)

    # Unlogged, like the write: a value pasted where a name belongs would
    # otherwise be the query's parameter.
    with %Secret{} = secret <- lookup(key, name),
         {1, _} <- Foreman.Repo.delete_all(from s in Secret, where: s.id == ^secret.id) do
      Audit.log(
        scope,
        "secret.delete",
        secret,
        Map.merge(audit, %{"scope" => key, "name" => name})
      )

      true
    else
      _ -> false
    end
  end

  # The first reason a secret was refused, as a sentence fragment: "name
  # must start with a letter…", "value should be at most 65536 byte(s)".
  defp refusal(changeset) do
    {field, [message | _]} =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {text, opts} ->
        Regex.replace(~r/%{(\w+)}/, text, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
      |> Enum.min()

    "#{field} #{message}"
  end

  # Serialize an environment write with the update that marks it destroyed.
  defp while_live(%Environment{id: id}, save) do
    Foreman.Repo.transact(fn ->
      query = from e in Environment, where: e.id == ^id and is_nil(e.destroyed_at), select: e.id
      query = if Foreman.Repo.sqlite?(), do: query, else: lock(query, "FOR UPDATE")
      if Foreman.Repo.one(query), do: save.(), else: {:error, :unauthorized}
    end)
  end

  defp while_live(_subject, save), do: save.()

  defp save_secret(scope, scope_name, subject, attrs, audit \\ %{}) do
    key = scope_key(scope_name, subject)
    name = attrs["name"] || attrs[:name]
    existing = name && lookup(key, name)

    secret =
      existing ||
        %Secret{scope: scope_name, scope_key: key}
        |> Map.merge(subject_fields(scope_name, subject))

    # Without repo_ids, a replaced value keeps the secret's repos: a
    # secret limited to one repo mustn't reach all of them on rotation.
    attrs =
      case stringify(attrs) do
        %{"repo_ids" => ids} = attrs -> %{attrs | "repo_ids" => List.wrap(ids)}
        attrs -> Map.put(attrs, "repo_ids", if(existing, do: existing.repo_ids, else: []))
      end

    # The timestamp moves on every set. Left to Ecto, setting the value a
    # secret already holds would change nothing, and anyone who can list
    # names would learn that the value they sent was the one stored.
    changeset =
      secret
      |> Secret.changeset(attrs)
      |> Ecto.Changeset.put_change(:updated_by_id, Scope.user_id(scope))
      |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())

    # Ecto logs a write's parameters as they were cast, before the column
    # type encrypts them, so this write stays out of the query log.
    with {:ok, saved} <- Foreman.Repo.insert_or_update(changeset, log: false) do
      Audit.log(
        scope,
        if(existing, do: "secret.update", else: "secret.create"),
        saved,
        Map.merge(audit, %{"scope" => key, "name" => saved.name})
      )

      {:ok, %{saved | value: nil}}
    end
  end

  @doc "Delete an environment's own secrets after its destruction has been recorded."
  def delete_environment_secrets(%Environment{id: id, destroyed_at: at}) when not is_nil(at) do
    Foreman.Repo.delete_all(
      from s in Secret, where: s.scope == "environment" and s.environment_id == ^id
    )
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

  @doc """
  Moves an environment's secret up a level, for the environment's owner:
  to their own secrets, limited to the environment's repo, or to the
  repo's if they're an admin. The value moves as it is; nobody has to see
  it. Only the owner can do it, since anywhere else the secret lands is
  somewhere the person moving it could read it from.

  Refuses when the level above already has a secret with that name, or
  when a level in between would override the moved secret in this
  environment, since either would change what the environment gets.
  """
  def promote_secret(%Scope{} = scope, %Environment{} = env, name, to) when is_binary(name) do
    env = Foreman.Repo.preload(env, [:repo, :user])

    with {:ok, target, attrs} <- promotion_target(to, env),
         true <- Scope.user_id(scope) == env.user_id || {:error, :unauthorized},
         :ok <- authorize(scope, to, target),
         {:ok, promoted} <- move_secret(scope, env, name, to, target, attrs) do
      Foreman.Environments.secrets_changed(affected_environment_ids(to, target))
      {:ok, %{promoted | value: nil}}
    end
  end

  def promote_secret(%Scope{}, _subject, _name, _to), do: {:error, :unauthorized}

  defp promotion_target("repo", env), do: {:ok, env.repo, %{"repo_ids" => []}}
  defp promotion_target("user", env), do: {:ok, env.user, %{"repo_ids" => [env.repo_id]}}
  defp promotion_target(_to, _env), do: {:error, :unauthorized}

  # Read and deleted in the transaction, and only if unchanged since the
  # read: a value replaced meanwhile isn't lost, or moved in its old form.
  defp move_secret(scope, env, name, to, target, attrs) do
    Foreman.Repo.transact(fn ->
      source = scope_key("environment", env)

      with %Secret{} = secret <- Foreman.Repo.get_by(Secret, scope_key: source, name: name),
           nil <- Foreman.Repo.get_by(Secret, scope_key: scope_key(to, target), name: name),
           {:ok, promoted} <- insert_promoted(scope, secret, to, target, attrs),
           {1, _} <-
             Foreman.Repo.delete_all(
               from s in Secret, where: s.id == ^secret.id and s.updated_at == ^secret.updated_at
             ),
           true <- resolve(env)[name] == secret.value || {:error, :overridden} do
        Audit.log(scope, "secret.promote", promoted, %{
          "from" => source,
          "scope" => promoted.scope_key,
          "name" => name
        })

        {:ok, promoted}
      else
        nil -> {:error, :not_found}
        %Secret{} -> {:error, :exists}
        {0, _} -> {:error, :not_found}
        {:error, %Ecto.Changeset{errors: [name: {"already exists here", _}]}} -> {:error, :exists}
        error -> error
      end
    end)
  end

  defp insert_promoted(scope, secret, to, target, attrs) do
    %Secret{scope: to, scope_key: scope_key(to, target)}
    |> Map.merge(subject_fields(to, target))
    |> Secret.changeset(Map.merge(attrs, %{"name" => secret.name, "value" => secret.value}))
    |> Ecto.Changeset.put_change(:updated_by_id, Scope.user_id(scope))
    |> Foreman.Repo.insert(log: false)
  end

  defp lookup(key, name),
    do: Foreman.Repo.get_by(Secret, [scope_key: key, name: name], log: false)

  defp subject_fields("owner", %Owner{id: id}), do: %{owner_id: id}
  defp subject_fields("repo", %Repo{id: id}), do: %{repo_id: id}
  defp subject_fields("user", %User{id: id}), do: %{user_id: id}
  defp subject_fields("environment", %Environment{id: id}), do: %{environment_id: id}

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  @doc "The live environments a scope's secrets reach."
  def affected_environment_ids(scope_name, subject) do
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
  def resolve(%Environment{} = env, opts \\ []) do
    ids = Keyword.get_lazy(opts, :approved_ids, fn -> service_secret_ids(env) end)

    env
    |> env_secrets(Keyword.get(opts, :include_shared, true), ids, Keyword.get(opts, :lock, false))
    |> Enum.concat()
    |> Enum.reduce(%{}, fn s, acc -> Map.put(acc, s.name, s.value) end)
  end

  defp service_secret_ids(env) do
    case Foreman.Repo.preload(env, :user).user do
      %{service_account: true} ->
        case Foreman.OAuth.ServiceAccounts.principal_for_user(env.user_id) do
          {:ok, principal} -> Foreman.OAuth.ServiceAccounts.secret_ids(principal)
          :error -> []
        end

      _ ->
        :all
    end
  end

  def shared?(%Environment{} = env) do
    keys = shared_keys(env)
    Foreman.Repo.exists?(from s in Secret, where: s.scope_key in ^keys)
  end

  defp shared_keys(env), do: ["owner:" <> env.repo.owner_id, "repo:" <> env.repo_id]

  # The secrets that reach an environment, one list per scope from owner
  # to environment. A user secret limited to other repos doesn't.
  defp env_secrets(
         %Environment{} = env,
         include_shared \\ true,
         approved_ids \\ :all,
         lock? \\ false
       ) do
    env = Foreman.Repo.preload(env, :repo)

    shared = if include_shared, do: shared_keys(env), else: []
    keys = shared ++ ["user:" <> env.user_id, "environment:" <> env.id]

    query = from(s in Secret, where: s.scope_key in ^keys, order_by: s.name)

    query =
      if approved_ids == :all,
        do: query,
        else: where(query, [s], s.id in ^approved_ids and s.scope in ["owner", "repo"])

    query = lock_selected(query, approved_ids, lock?)

    by_key =
      query
      |> Foreman.Repo.all()
      |> Enum.filter(fn s ->
        s.scope != "user" or s.repo_ids == [] or env.repo_id in s.repo_ids
      end)
      |> Enum.group_by(& &1.scope_key)

    Enum.map(keys, &Map.get(by_key, &1, []))
  end

  defp lock_selected(query, _ids, false), do: query

  defp lock_selected(query, ids, true) do
    cond do
      Foreman.Repo.sqlite?() ->
        # The delivery transaction already holds the database write reservation.
        query

      ids == :all ->
        # A new, higher-priority row can shadow an existing value. Hold inserts
        # as well as rotations until the short, local mailbox handoff finishes.
        Foreman.Repo.query!("LOCK TABLE secrets IN SHARE MODE")
        query

      true ->
        # The allowlist names existing immutable IDs. Unrelated inserts cannot
        # affect these values and should proceed during service-account delivery.
        lock(order_by(query, [s], s.id), "FOR SHARE")
    end
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
