defmodule Foreman.PublicAPI.Secrets do
  @moduledoc """
  Secrets for a personal public API connection: which scope a request
  names, whether the caller may manage it, and one request's changes.

  The caller checks the connection's action scope first. Roles follow
  `Foreman.Secrets.authorize/3`: a person's own secrets and their own
  environments' are theirs, and a repository's or an owner's take an
  admin. A member is refused those before anything is looked up, so the
  answer doesn't say whether the repository or owner exists. Values are
  written and never read back.
  """
  import Ecto.Query

  alias Foreman.{Accounts, Repo, Repos, Scope}
  alias Foreman.Environments.Environment
  alias Foreman.OAuth.Principal
  alias Foreman.PublicAPI.Access
  alias Foreman.Secrets.Secret

  @max_changes 100
  # The shape of a name, checked before anything is looked up by it. The
  # changeset says which well-formed names are reserved.
  @name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  # Never repeats what was sent: a value pasted where a name belongs
  # would come back in the error.
  @invalid {:error, :invalid_request,
            "Send secrets as a list of {name, value} and unset as a list of names, " <>
              "with at least one change and at most #{@max_changes}, and each name once. " <>
              "A name starts with a letter or underscore and holds only letters, digits " <>
              "and underscores."}

  @doc """
  The scope and subject a path names, for a caller who may manage it.
  `{:error, :missing}` when it doesn't exist or isn't the caller's to see,
  `{:error, :role}` when it takes an admin or a personal connection.
  """
  def subject(%Principal{kind: :user} = principal, scope, raw) when is_binary(raw) do
    admin? = Scope.admin?(Scope.for_user(principal.user))

    cond do
      not Access.connected?(principal) -> {:error, :missing}
      scope in ["repo", "owner"] and not admin? -> {:error, :role}
      true -> find(principal, scope, raw)
    end
  end

  def subject(%Principal{}, _scope, _raw), do: {:error, :role}

  defp find(%{user: user}, "user", raw) do
    if raw in ["me", user.id], do: {:ok, "user", user}, else: {:error, :missing}
  end

  defp find(principal, "environment", raw) do
    with {:ok, id} <- uuid(raw) do
      found(Repo.one(Access.live_environments(principal, id)), "environment")
    end
  end

  defp find(principal, "repo", raw) do
    with {:ok, id} <- uuid(raw) do
      found(Repo.one(Access.repos(principal, id)), "repo")
    end
  end

  defp find(_principal, "owner", raw) do
    owner =
      case uuid(raw) do
        {:ok, id} -> Repo.get(Repos.Owner, id)
        _ -> Repos.get_owner_by_login(raw)
      end

    found(owner, "owner")
  end

  defp find(_principal, _scope, _raw), do: {:error, :missing}

  defp found(nil, _scope), do: {:error, :missing}
  defp found(subject, scope), do: {:ok, scope, subject}

  defp uuid(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, id} when byte_size(raw) == 36 -> {:ok, id}
      _ -> {:error, :missing}
    end
  end

  @doc """
  A scope's secrets as rows without values, for a keyset page by name.
  The connection's grant is checked in the statement that reads them.
  """
  def listing(principal, scope, subject) do
    key = Foreman.Secrets.scope_key(scope, subject)

    from(s in Secret, where: s.scope_key == ^key, select: map(s, [:id, :name, :updated_at]))
    |> Access.while_connected(principal)
  end

  @doc """
  Applies one request's changes to a scope the caller may manage. Returns
  the names set and removed, the caller's running environments the scope
  reaches, and how many of other people's it reaches.

  Which environments are reported never depends on the values sent: one
  that already held the same value is listed like any other.
  """
  def change(%Principal{} = principal, scope, subject, params) do
    with {:ok, set, unset} <- input(params) do
      actor = Scope.for_user(principal.user)
      # Everything that asks GitHub is asked here, before the transaction
      # opens. A failure to reach it then fails the request with nothing
      # written, and what runs afterwards is local SQL.
      retained = retained(principal, scope, subject)
      listable = listable(principal, scope, retained)

      opts = [
        audit: audit(principal),
        recheck: fn -> still_allowed(principal, scope, retained) end
      ]

      case Foreman.Secrets.apply_changes(actor, scope, subject, set, unset, opts) do
        {:ok, changed} ->
          {:ok, Map.merge(changed, reached(principal, scope, subject, listable))}

        {:error, {:invalid, name, message}} ->
          {:error, :invalid_request, "#{name}: #{message}"}

        {:error, :role} ->
          {:error, :role}

        # The subject was the caller's a moment ago: it has just been
        # destroyed or archived, or the connection has just been revoked.
        {:error, _} ->
          {:error, :resource_not_found, "Resource not found."}
      end
    end
  end

  # The query that established the caller's access to the subject, kept to
  # run again under the write's locks.
  defp retained(principal, "environment", env), do: Access.live_environments(principal, env.id)
  defp retained(principal, "repo", repo), do: Access.repos(principal, repo.id)
  defp retained(_principal, _scope, _subject), do: nil

  # The environments this connection could list, or nil when it may not.
  defp listable(principal, scope, retained) do
    cond do
      "environments:list" not in principal.scopes -> nil
      scope == "environment" -> retained
      true -> Access.live_environments(principal)
    end
  end

  # Authentication and `subject/3` ran before the transaction opened, and
  # a repository lookup can wait on GitHub in between. Inside it, after
  # the scope's turn has come: the grant is still live (and locked, so a
  # revocation waits), an admin is still one, and the subject is still
  # the caller's to reach.
  defp still_allowed(principal, scope, retained) do
    cond do
      not Access.lock_connection(principal) ->
        {:error, :missing}

      scope in ["repo", "owner"] and not admin?(principal) ->
        {:error, :role}

      retained && not Repo.exists?(retained) ->
        {:error, :missing}

      true ->
        :ok
    end
  end

  defp admin?(principal),
    do: match?({:ok, _}, Accounts.lock_admin(Scope.for_user(principal.user)))

  defp input(%{} = params) do
    with [] <- Map.keys(params) -- ["secrets", "unset"],
         {:ok, set} <- pairs(Map.get(params, "secrets", [])),
         {:ok, unset} <- names(Map.get(params, "unset", [])),
         all = Enum.map(set, &elem(&1, 0)) ++ unset,
         true <- all != [] and length(all) <= @max_changes and all == Enum.uniq(all),
         true <- Enum.all?(all, &Regex.match?(@name, &1)) do
      {:ok, set, unset}
    else
      _ -> @invalid
    end
  end

  defp input(_params), do: @invalid

  defp pairs(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"name" => name, "value" => value} = pair, {:ok, pairs}
      when is_binary(name) and is_binary(value) and map_size(pair) == 2 ->
        {:cont, {:ok, [{name, value} | pairs]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  defp pairs(_), do: :error

  defp names(list) when is_list(list),
    do: if(Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error)

  defp names(_), do: :error

  # The caller's running environments are named when the connection may
  # list environments, and other people's are only counted. Running, not
  # changed: reporting only those whose values differ would tell the
  # caller whether what they sent matched what was there.
  defp reached(principal, scope, subject, listable) do
    ids = Foreman.Secrets.affected_environment_ids(scope, subject)

    running =
      from e in Environment,
        where: e.id in ^ids and e.desired_state == "running" and is_nil(e.destroyed_at)

    own =
      if listable do
        from(e in listable,
          where: e.id in ^ids and e.desired_state == "running",
          order_by: e.slug,
          select: map(e, [:id, :slug])
        )
        |> Repo.all()
      else
        []
      end

    others = from e in running, where: e.user_id != ^principal.user.id
    %{affected: own, others_affected: Repo.aggregate(others, :count)}
  end

  defp audit(principal) do
    %{
      "client_id" => principal.client_id,
      "grant_id" => principal.grant_id,
      "actor_kind" => to_string(principal.kind)
    }
  end
end
