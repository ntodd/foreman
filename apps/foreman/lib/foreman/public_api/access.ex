defmodule Foreman.PublicAPI.Access do
  @moduledoc """
  Resource queries for an authenticated public API connection. The caller
  checks its action scope independently. Environment history uses the same
  ownership and current resource permissions after a workspace is destroyed.
  """
  import Ecto.Query

  alias Foreman.{Config, GitHub, OAuth}
  alias Foreman.Boxes.Box
  alias Foreman.Environments.Environment
  alias Foreman.Repos.Repo, as: GitRepo

  defmodule Unavailable do
    @moduledoc "GitHub could not confirm current repository access."
    defexception message: "Repository access could not be verified. Try again.", plug_status: 503
  end

  def boxes(%{kind: :service_account} = principal) do
    from(b in Box, where: is_nil(b.revoked_at))
    |> service_resources(principal, :box_ids)
  end

  def boxes(%{kind: :user, user: user} = principal) do
    grant =
      from g in matching_grants(principal),
        join: account in assoc(g, :user),
        select: %{role: account.role, service: account.service_account}

    from b in Box,
      join: actor in subquery(grant),
      on: not actor.service,
      where: is_nil(b.revoked_at),
      where:
        (^user.role == "admin" and actor.role == "admin") or
          b.owner_user_id == ^user.id or ^user.id in b.shared_user_ids
  end

  def repos(principal, id \\ :all) do
    query = from r in GitRepo, where: not r.archived and is_nil(r.removed_at)
    query = by_id(query, id)
    authorized_repos(query, principal)
  rescue
    # A selector alone does not establish that a private repo exists.
    error in Unavailable ->
      if id == :all, do: reraise(error, __STACKTRACE__), else: where(GitRepo, false)
  end

  def environments(principal, id \\ :all),
    do: visible_environments(owned_environments(principal), principal, id)

  def live_environments(principal, id \\ :all) do
    owned_environments(principal)
    |> where([e], is_nil(e.destroyed_at))
    |> visible_environments(principal, id)
  end

  defp visible_environments(owned, principal, id) do
    owned = by_id(owned, id)
    candidates = select(owned, [e], e.repo_id)
    query = from r in GitRepo, where: is_nil(r.removed_at) and r.id in subquery(candidates)
    allowed = authorized_repos(query, principal)

    from e in owned,
      join: r in subquery(allowed),
      on: r.id == e.repo_id,
      where: is_nil(r.github_identity_bound_at) or r.github_identity_bound_at <= e.inserted_at
  end

  defp authorized_repos(query, %{kind: :service_account} = principal) do
    query = if GitHub.configured?(), do: where(query, [r], not is_nil(r.github_id)), else: query
    service_resources(query, principal, :repo_ids)
  end

  defp authorized_repos(query, %{kind: :user, user: user} = principal) do
    grants = matching_grants(principal)
    query = where(query, exists(subquery(grants)))

    cond do
      GitHub.configured?() ->
        ids = Foreman.PublicAPI.RepositoryAccess.visible_ids(query, user)
        where(query, [r], r.id in ^ids)

      local_git?() ->
        where(query, [r], not r.private)

      true ->
        where(query, false)
    end
  end

  defp owned_environments(principal) do
    box_ids = select(boxes(principal), [b], b.id)

    from e in Environment,
      where: e.user_id == ^principal.user.id and e.box_id in subquery(box_ids)
  end

  # Keep the installation check in the final SQL statement: callers can
  # prepare a query before entering the placement transaction.
  defp service_resources(query, principal, field) do
    grant = matching_grants(principal)

    from resource in query,
      join: g in subquery(grant),
      on: type(resource.id, :string) in field(g, ^field)
  end

  defp matching_grants(principal) do
    from g in OAuth.live_grants(),
      where:
        g.id == ^principal.grant_id and g.client_id == ^principal.client_id and
          g.user_id == ^principal.user.id
  end

  defp by_id(query, :all), do: query
  defp by_id(query, id), do: where(query, [r], r.id == ^id)

  defp local_git? do
    case URI.parse(Config.git_base_url()) do
      %URI{host: host, scheme: scheme} when is_binary(host) and scheme in ["http", "https"] ->
        String.downcase(host) not in ["github.com", "www.github.com"]

      _ ->
        false
    end
  end
end
