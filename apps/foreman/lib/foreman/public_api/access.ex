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

    from(b in Box,
      join: actor in subquery(grant),
      on: not actor.service,
      where: is_nil(b.revoked_at),
      where:
        (^user.role == "admin" and actor.role == "admin") or
          b.owner_user_id == ^user.id or ^user.id in b.shared_user_ids
    )
    |> own_box(principal)
  end

  # An environment's own connection reaches the box it runs on, which its
  # owner must still have, and no other.
  defp own_box(query, %{environment_id: nil}), do: query

  defp own_box(query, %{environment_id: id}) do
    host = from e in Environment, where: e.id == ^id, select: e.box_id
    where(query, [b], b.id in subquery(host))
  end

  def repos(principal, id \\ :all)

  # An environment's own connection lists and launches nothing. Its own
  # repository is checked where the environment is read.
  def repos(%{environment_id: id}, _id) when not is_nil(id), do: where(GitRepo, false)

  def repos(principal, id) do
    # Personal verification can observe an archive or unarchive for manual
    # repos outside an installation. Apply the launch filter after it runs.
    from(r in GitRepo, where: is_nil(r.removed_at) and (not r.archived or r.manual))
    |> by_id(id)
    |> authorized_repos(principal)
    |> where([r], not r.archived)
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

    from(e in Environment,
      join: r in assoc(e, :repo),
      where:
        e.repo_github_id == r.github_id or (is_nil(e.repo_github_id) and is_nil(r.github_id)),
      where: e.user_id == ^principal.user.id and e.box_id in subquery(box_ids)
    )
    |> own_environment(principal)
  end

  defp own_environment(query, %{environment_id: nil}), do: query
  defp own_environment(query, %{environment_id: id}), do: where(query, [e], e.id == ^id)

  # Keep the installation check in the final SQL statement: callers can
  # prepare a query before entering the placement transaction.
  defp service_resources(query, principal, field) do
    grant = matching_grants(principal)

    from resource in query,
      join: g in subquery(grant),
      on: type(resource.id, :string) in field(g, ^field)
  end

  @doc """
  Whether the connection's grant is still live. The resource queries
  above check it in the same statement that reads the resource; this is
  for a subject they don't cover.
  """
  def connected?(principal), do: Foreman.Repo.exists?(matching_grants(principal))

  @doc """
  The same check inside a transaction, holding the grant row: a
  revocation that hasn't committed yet waits for the caller, and one
  that has is seen. Shared, and on the grant alone, so two writers
  through one client don't queue behind each other on its row.

  The user's row is taken first, the order token refresh and
  offboarding take the two in. A write that audits itself needs that
  row anyway, for the audit entry's reference to its actor, and taking
  it after the grant would cross with a refresh in flight.
  """
  def lock_connection(principal) do
    grant = from g in matching_grants(principal), select: g.id

    unless Foreman.Repo.sqlite?() do
      user = from u in Foreman.Accounts.User, where: u.id == ^principal.user.id, select: u.id
      Foreman.Repo.one(lock(user, "FOR SHARE"))
    end

    grant =
      if Foreman.Repo.sqlite?(),
        do: grant,
        else: lock(grant, [g], fragment("FOR SHARE OF ?", g))

    not is_nil(Foreman.Repo.one(grant))
  end

  @doc "Narrows a query to nothing unless the connection's grant is still live."
  def while_connected(query, principal),
    do: where(query, exists(subquery(matching_grants(principal))))

  defp matching_grants(principal) do
    from g in OAuth.live_grants(),
      where:
        g.id == ^principal.grant_id and g.client_id == ^principal.client_id and
          g.user_id == ^principal.user.id
  end

  defp by_id(query, :all), do: query
  defp by_id(query, id), do: where(query, [r], r.id == ^id)
end
