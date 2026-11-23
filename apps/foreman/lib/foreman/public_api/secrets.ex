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

  alias Foreman.{Repo, Repos, Scope}
  alias Foreman.Environments.Environment
  alias Foreman.OAuth.Principal
  alias Foreman.PublicAPI.Access
  alias Foreman.Secrets.Secret

  @max_changes 100
  @invalid {:error, :invalid_request,
            "Send secrets as a list of {name, value} and unset as a list of names, " <>
              "with at least one change and at most #{@max_changes}, and each name once."}

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

  @doc "A scope's secrets as rows without values, for a keyset page by name."
  def listing(scope, subject) do
    key = Foreman.Secrets.scope_key(scope, subject)
    from s in Secret, where: s.scope_key == ^key, select: map(s, [:id, :name, :updated_at])
  end

  @doc """
  Applies one request's changes to a scope the caller may manage. Returns
  the names set and removed, the caller's own environments now waiting on
  a restart, and how many of other people's are.
  """
  def change(%Principal{} = principal, scope, subject, params) do
    with {:ok, set, unset} <- input(params) do
      actor = Scope.for_user(principal.user)

      case Foreman.Secrets.apply_changes(actor, scope, subject, set, unset,
             audit: audit(principal)
           ) do
        {:ok, changed} ->
          {:ok, Map.merge(changed, pending(principal, scope, subject))}

        {:error, {:invalid, name, message}} ->
          {:error, :invalid_request, "#{name}: #{message}"}

        # The subject was the caller's a moment ago: it has just been
        # destroyed, or their role has just changed.
        {:error, :unauthorized} ->
          {:error, :resource_not_found, "Resource not found."}
      end
    end
  end

  defp input(%{} = params) do
    with [] <- Map.keys(params) -- ["secrets", "unset"],
         {:ok, set} <- pairs(Map.get(params, "secrets", [])),
         {:ok, unset} <- names(Map.get(params, "unset", [])),
         all = Enum.map(set, &elem(&1, 0)) ++ unset,
         true <- all != [] and length(all) <= @max_changes and all == Enum.uniq(all) do
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

  # Environments of the caller's are named, since the caller can see
  # those; everyone else's are only counted.
  defp pending(principal, scope, subject) do
    waiting =
      from e in Environment,
        where: e.id in ^Foreman.Secrets.affected_environment_ids(scope, subject),
        where: e.pending_restart and is_nil(e.destroyed_at)

    own = from e in waiting, where: e.user_id == ^principal.user.id, order_by: e.slug

    %{
      pending_restart: Repo.all(from e in own, select: map(e, [:id, :slug])),
      others_pending_restart:
        Repo.aggregate(from(e in waiting, where: e.user_id != ^principal.user.id), :count)
    }
  end

  defp audit(principal) do
    %{
      "client_id" => principal.client_id,
      "grant_id" => principal.grant_id,
      "actor_kind" => to_string(principal.kind)
    }
  end
end
