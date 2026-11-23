defmodule Foreman.PublicAPI.Access do
  @moduledoc """
  Resource queries for an authenticated public API connection. The caller
  checks its action scope independently. Environment history uses the same
  ownership and current resource permissions after a workspace is destroyed.
  """
  import Ecto.Query

  alias Foreman.{Config, GitHub, OAuth, Repo}
  alias Foreman.Boxes.Box
  alias Foreman.Environments.Environment
  alias Foreman.GitHub.Client
  alias Foreman.Repos.Repo, as: GitRepo

  defmodule Unavailable do
    @moduledoc "GitHub could not confirm current repository access."
    defexception message: "Repository access could not be verified. Try again.", plug_status: 503
  end

  def boxes(%{kind: :service_account} = principal) do
    from(b in Box, where: is_nil(b.revoked_at))
    |> service_resources(principal, :box_ids)
  end

  def boxes(%{kind: :user, user: user}) do
    query = from b in Box, where: is_nil(b.revoked_at)

    if user.role == "admin" do
      query
    else
      from b in query, where: b.owner_user_id == ^user.id or ^user.id in b.shared_user_ids
    end
  end

  def repos(principal, id \\ :all)

  def repos(%{kind: :service_account} = principal, id) do
    active_repos() |> by_id(id) |> service_resources(principal, :repo_ids)
  end

  def repos(%{kind: :user, user: user}, id) do
    query = by_id(active_repos(), id)

    cond do
      GitHub.configured?() ->
        ids = github_repo_ids(user, id, query)
        where(query, [r], r.id in ^ids)

      local_git?() ->
        where(query, [r], not r.private)

      true ->
        where(query, false)
    end
  end

  def environments(principal) do
    visible_in_repos(owned_environments(principal), repos(principal))
  end

  def environments(principal, id) do
    query = by_id(owned_environments(principal), id)

    case Repo.one(select(query, [e], e.repo_id)) do
      nil -> where(query, false)
      repo_id -> visible_in_repos(query, repos(principal, repo_id))
    end
  end

  defp owned_environments(principal) do
    box_ids = select(boxes(principal), [b], b.id)

    from e in Environment,
      where: e.user_id == ^principal.user.id and e.box_id in subquery(box_ids)
  end

  defp visible_in_repos(query, repos) do
    repo_ids = select(repos, [r], r.id)
    where(query, [e], e.repo_id in subquery(repo_ids))
  end

  # Keep the installation check in the final SQL statement: callers can
  # prepare a query before entering the placement transaction.
  defp service_resources(query, principal, field) do
    grant =
      from g in OAuth.live_grants(),
        where:
          g.id == ^principal.grant_id and g.client_id == ^principal.client_id and
            g.user_id == ^principal.user.id

    from resource in query,
      join: g in subquery(grant),
      on: type(resource.id, :string) in field(g, ^field)
  end

  defp by_id(query, :all), do: query
  defp by_id(query, id), do: where(query, [r], r.id == ^id)

  defp active_repos, do: from(r in GitRepo, where: not r.archived and is_nil(r.removed_at))

  defp local_git? do
    case URI.parse(Config.git_base_url()) do
      %URI{host: host, scheme: scheme} when is_binary(host) and scheme in ["http", "https"] ->
        String.downcase(host) not in ["github.com", "www.github.com"]

      _ ->
        false
    end
  end

  defp github_repo_ids(user, id, query) do
    case GitHub.user_token(user) do
      {:ok, token} ->
        github_repo_ids_with_token(token, id, query)

      {:error, :login_expired} ->
        []

      {:error, _} ->
        raise Unavailable
    end
  end

  defp github_repo_ids_with_token(token, :all, query) do
    from(r in query,
      join: o in assoc(r, :owner),
      select: {o.installation_id, r.id, r.github_id, r.full_name}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {installation, records} ->
      installation_repo_ids(token, installation, records)
    end)
  end

  defp github_repo_ids_with_token(token, _id, query) do
    for {id, github_id, name} <- Repo.all(select(query, [r], {r.id, r.github_id, r.full_name})),
        readable_repo?(token, github_id, name),
        do: id
  end

  defp installation_repo_ids(token, nil, records) do
    # Repositories can also be added manually, without an installation.
    for {_, id, github_id, name} <- records,
        readable_repo?(token, github_id, name),
        do: id
  end

  defp installation_repo_ids(token, installation, records) do
    case Client.impl().list_user_installation_repos(token, installation) do
      {:ok, repositories} ->
        by_name = Map.new(repositories, &{String.downcase(&1["full_name"]), &1["id"]})

        for {_, id, github_id, name} <- records,
            remote_id = by_name[String.downcase(name)],
            is_nil(github_id) or github_id == remote_id,
            do: id

      {:error, {:http, 404, _}} ->
        []

      {:error, _} ->
        raise Unavailable
    end
  end

  defp readable_repo?(token, github_id, name) do
    case Client.impl().get_repo(token, name) do
      {:ok, %{"full_name" => full_name, "id" => id}} ->
        String.downcase(full_name) == String.downcase(name) and
          (is_nil(github_id) or github_id == id)

      {:error, :not_found} ->
        false

      _ ->
        raise Unavailable
    end
  end
end
