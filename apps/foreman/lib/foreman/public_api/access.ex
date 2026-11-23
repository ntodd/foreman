defmodule Foreman.PublicAPI.Access do
  @moduledoc """
  Resource queries for an authenticated public API connection. The caller
  checks its action scope independently. Environment history uses the same
  ownership and current resource permissions after a workspace is destroyed.
  """
  import Ecto.Query

  alias Foreman.{GitHub, OAuth}
  alias Foreman.PublicAPI.RepositoryAccess
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

  @doc "Approved clone repositories, including an archived primary on an existing accessible workspace."
  def service_workload_repos(%{kind: :service_account} = principal, primary_id) do
    existing =
      from e in environments(principal),
        where: e.repo_id == ^primary_id and e.created_once and is_nil(e.destroyed_at),
        select: e.repo_id

    from(r in GitRepo,
      where: is_nil(r.removed_at) and (not r.archived or r.id in subquery(existing))
    )
    |> authorized_repos(principal)
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
      on: r.id == e.repo_id
  end

  defp authorized_repos(query, %{kind: :service_account} = principal) do
    resources = service_resources(RepositoryAccess.grantable(query), principal, :repo_ids)

    from [r, ..., grant] in resources,
      join: approved in Foreman.OAuth.GrantRepository,
      on: approved.grant_id == grant.id and approved.repo_id == r.id,
      where:
        approved.github_id == r.github_id or (is_nil(approved.github_id) and is_nil(r.github_id))
  end

  defp authorized_repos(query, %{kind: :user, user: user} = principal) do
    grants = matching_grants(principal)
    query = where(query, exists(subquery(grants)))

    cond do
      GitHub.configured?() ->
        RepositoryAccess.verified_query(query, user)

      RepositoryAccess.local_git?() ->
        where(query, [r], not r.private)

      true ->
        where(query, false)
    end
  end

  defp owned_environments(principal) do
    box_ids = select(boxes(principal), [b], b.id)

    from e in Environment,
      join: r in assoc(e, :repo),
      where:
        e.repo_github_id == r.github_id or (is_nil(e.repo_github_id) and is_nil(r.github_id)),
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
end
