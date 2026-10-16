defmodule Foreman.Repos do
  @moduledoc """
  The GitHub owners and repos Foreman knows about: synced from the GitHub
  App's installations, or added by hand. Repo settings control the
  environment token's scope, Tailscale tags and default limits.
  """
  import Ecto.Query

  alias Foreman.{Audit, Repo, Scope}
  alias Foreman.Repos.Owner
  alias Foreman.Repos.Repo, as: GitRepo

  def list_owners, do: Owner |> order_by(:login) |> Repo.all()
  def get_owner!(id), do: Repo.get!(Owner, id)
  def get_owner_by_login(login), do: Repo.get_by(Owner, login: login)

  def list_repos(opts \\ []) do
    query =
      from r in GitRepo,
        where: r.archived == false and is_nil(r.removed_at),
        order_by: r.full_name,
        preload: :owner

    query =
      if Keyword.get(opts, :with_devcontainer, false),
        do: where(query, [r], not is_nil(r.devcontainer_path)),
        else: query

    Repo.all(query)
  end

  def get_repo!(id), do: GitRepo |> Repo.get!(id) |> Repo.preload(:owner)

  def get_repo_by_full_name(full_name),
    do: GitRepo |> Repo.get_by(full_name: full_name) |> Repo.preload(:owner)

  @doc """
  Creates or updates an owner from GitHub's account data, matched by
  GitHub id first so a renamed org keeps its row.
  """
  def upsert_owner(attrs) do
    github_id = attrs[:github_id] || attrs["github_id"]
    login = attrs[:login] || attrs["login"]

    owner =
      (github_id && Repo.get_by(Owner, github_id: github_id)) ||
        Repo.get_by(Owner, login: login) || %Owner{}

    owner |> Owner.changeset(attrs) |> Repo.insert_or_update()
  end

  @doc """
  Creates or updates a repo from GitHub's data (or a manual add). A repo
  is matched by its GitHub id first, so a rename or transfer updates the
  row, keeping its settings, secrets and environments.
  """
  def upsert_repo(%Owner{} = owner, attrs) do
    full_name = attrs[:full_name] || attrs["full_name"]
    by_name = Repo.get_by(GitRepo, full_name: full_name)

    repo =
      case by_github_id(attrs[:github_id] || attrs["github_id"]) do
        # Renamed or transferred, unless another row already has the new
        # name (one created before ids were matched); that one wins.
        %GitRepo{} = repo when is_nil(by_name) or by_name.id == repo.id -> repo
        _ -> by_name || %GitRepo{owner_id: owner.id}
      end

    repo
    |> GitRepo.sync_changeset(attrs)
    |> Ecto.Changeset.put_change(:owner_id, owner.id)
    |> Repo.insert_or_update()
  end

  defp by_github_id(nil), do: nil

  defp by_github_id(id) do
    from(r in GitRepo, where: r.github_id == ^id, order_by: r.inserted_at, limit: 1)
    |> Repo.one()
  end

  @doc """
  Marks `owner`'s synced repos that aren't in `github_ids` (the
  installation's complete repo list) as removed, so they leave the repo
  list. Manually added repos aren't touched.
  """
  def mark_removed(%Owner{id: owner_id}, github_ids) do
    from(r in GitRepo,
      where:
        r.owner_id == ^owner_id and r.manual == false and is_nil(r.removed_at) and
          not is_nil(r.github_id) and r.github_id not in ^github_ids
    )
    |> Repo.update_all(set: [removed_at: DateTime.utc_now()])
  end

  @doc "Admins can add a repo by name, e.g. a public repo outside the installation."
  def add_repo(%Scope{} = scope, full_name, attrs \\ %{}) do
    with :ok <- authorize_admin(scope),
         [owner_login, name] <- String.split(full_name, "/", parts: 2),
         {:ok, owner} <- get_or_create_owner(owner_login),
         {:ok, repo} <-
           upsert_repo(owner, Map.merge(%{full_name: full_name, name: name, manual: true}, attrs)) do
      Audit.log(scope, "repo.add", repo)
      {:ok, Repo.preload(repo, :owner)}
    else
      [_] -> {:error, :invalid_name}
      error -> error
    end
  end

  defp get_or_create_owner(login) do
    case get_owner_by_login(login) do
      nil -> upsert_owner(%{login: login})
      owner -> {:ok, owner}
    end
  end

  def update_repo_settings(%Scope{} = scope, %GitRepo{} = repo, attrs) do
    with :ok <- authorize_admin(scope),
         {:ok, repo} <-
           repo |> GitRepo.settings_changeset(normalize_settings(attrs)) |> Repo.update() do
      Audit.log(scope, "repo.settings", repo)
      {:ok, repo}
    end
  end

  def change_repo_settings(%GitRepo{} = repo, attrs \\ %{}),
    do: GitRepo.settings_changeset(repo, normalize_settings(attrs))

  # Form fields arrive as comma-separated strings.
  defp normalize_settings(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> split_list("extra_repos")
    |> split_list("tailscale_tags")
    |> blank_to_nil("cpu_limit")
    |> blank_to_nil("memory_limit_mb")
  end

  defp split_list(attrs, key) do
    case attrs[key] do
      value when is_binary(value) ->
        Map.put(
          attrs,
          key,
          value |> String.split([",", " ", "\n"], trim: true) |> Enum.map(&String.trim/1)
        )

      _ ->
        attrs
    end
  end

  defp blank_to_nil(attrs, key) do
    if attrs[key] == "", do: Map.put(attrs, key, nil), else: attrs
  end

  def update_registry(%Scope{} = scope, %Owner{} = owner, attrs) do
    with :ok <- authorize_admin(scope),
         {:ok, owner} <- owner |> Owner.registry_changeset(attrs) |> Repo.update() do
      Audit.log(scope, "owner.registry", owner, %{
        "host" => owner.registry_host,
        "username" => owner.registry_username
      })

      {:ok, owner}
    end
  end

  @doc "Repos whose devcontainer pulls from a private registry under `owner` while no credential is set."
  def missing_registry_credentials do
    from(r in GitRepo,
      join: o in assoc(r, :owner),
      where: is_nil(o.registry_token),
      preload: [owner: o]
    )
    |> Repo.all()
    |> Enum.filter(&(&1.private_registry_refs != []))
  end

  defp authorize_admin(scope), do: if(Scope.admin?(scope), do: :ok, else: {:error, :unauthorized})
end
