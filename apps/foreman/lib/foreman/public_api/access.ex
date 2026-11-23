defmodule Foreman.PublicAPI.Access do
  @moduledoc """
  Resource queries for an authenticated public API connection. The caller
  checks its action scope independently. Environment history uses the same
  ownership and current resource permissions after a workspace is destroyed.
  """
  import Ecto.Query

  alias Foreman.{Config, GitHub, Repo}
  alias Foreman.Boxes.Box
  alias Foreman.Environments.Environment
  alias Foreman.GitHub.Client
  alias Foreman.OAuth.ServiceAccounts
  alias Foreman.Repos.Repo, as: GitRepo

  defmodule Unavailable do
    @moduledoc "GitHub could not confirm current repository access."
    defexception message: "Repository access could not be verified. Try again.", plug_status: 503
  end

  def boxes(%{kind: :service_account} = principal) do
    ids = ServiceAccounts.box_ids(principal)
    from b in Box, where: is_nil(b.revoked_at) and b.id in ^ids
  end

  def boxes(%{kind: :user, user: user}) do
    query = from b in Box, where: is_nil(b.revoked_at)

    if user.role == "admin" do
      query
    else
      from b in query, where: b.owner_user_id == ^user.id or ^user.id in b.shared_user_ids
    end
  end

  def repos(%{kind: :service_account} = principal) do
    ids = ServiceAccounts.repo_ids(principal)
    where(active_repos(), [r], r.id in ^ids)
  end

  def repos(%{kind: :user, user: user}) do
    cond do
      GitHub.configured?() ->
        ids = github_repo_ids(user)
        where(active_repos(), [r], r.id in ^ids)

      local_git?() ->
        where(active_repos(), [r], not r.private)

      true ->
        where(active_repos(), false)
    end
  end

  def environments(principal) do
    repo_ids = select(repos(principal), [r], r.id)
    box_ids = select(boxes(principal), [b], b.id)

    from e in Environment,
      where: e.user_id == ^principal.user.id,
      where: e.repo_id in subquery(repo_ids) and e.box_id in subquery(box_ids)
  end

  defp active_repos, do: from(r in GitRepo, where: not r.archived and is_nil(r.removed_at))

  defp local_git? do
    case URI.parse(Config.git_base_url()) do
      %URI{host: host, scheme: scheme} when is_binary(host) and scheme in ["http", "https"] ->
        String.downcase(host) not in ["github.com", "www.github.com"]

      _ ->
        false
    end
  end

  defp github_repo_ids(user) do
    case GitHub.user_token(user) do
      {:ok, token} ->
        from(r in active_repos(),
          join: o in assoc(r, :owner),
          select: {o.installation_id, r.id, r.github_id, r.full_name}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0))
        |> Enum.flat_map(fn {installation, records} ->
          installation_repo_ids(token, installation, records)
        end)

      {:error, :login_expired} ->
        []

      {:error, _} ->
        raise Unavailable
    end
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
