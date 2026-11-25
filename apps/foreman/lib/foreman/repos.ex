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

  def devcontainer_scan_versions(owner) do
    from(r in GitRepo,
      where:
        r.owner_id == ^owner.id and not r.archived and is_nil(r.removed_at) and
          not is_nil(r.devcontainer_pushed_at),
      select: {r.github_id, {r.full_name, r.default_branch, r.devcontainer_pushed_at}}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get_repo!(id), do: GitRepo |> Repo.get!(id) |> Repo.preload(:owner)

  @doc "`%{id => full_name}` for the repos with these ids, listed or not."
  def full_names(ids),
    do: Map.new(Repo.all(from r in GitRepo, where: r.id in ^ids, select: {r.id, r.full_name}))

  def get_repo_by_full_name(full_name),
    do: GitRepo |> Repo.get_by(full_name: full_name) |> Repo.preload(:owner)

  @doc """
  Creates or updates an owner from GitHub's account data, matched by
  GitHub id first so a renamed org keeps its row.
  """
  # Logins move between accounts: an org renames, and another account can
  # take the old name. A row holding the login under another GitHub id is
  # that other account's, with its secrets and registry credential, so
  # it's moved out of the way instead of taken over; if that account still
  # exists, the next sync finds it by id and gives it its new login.
  def upsert_owner(attrs) do
    github_id = attrs[:github_id] || attrs["github_id"]
    login = attrs[:login] || attrs["login"]
    by_id = github_id && Repo.get_by(Owner, github_id: github_id)
    by_login = login && Repo.get_by(Owner, login: login)

    by_id
    |> owner_row(by_login, github_id)
    |> Owner.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp owner_row(nil, nil, _github_id), do: %Owner{}

  defp owner_row(nil, by_login, github_id) do
    if other_owner?(by_login, github_id), do: free_login(by_login, %Owner{}), else: by_login
  end

  defp owner_row(by_id, by_login, _github_id) do
    if by_login && by_login.id != by_id.id, do: free_login(by_login, by_id), else: by_id
  end

  defp other_owner?(%Owner{github_id: nil}, _github_id), do: false
  defp other_owner?(%Owner{}, nil), do: false
  defp other_owner?(%Owner{github_id: id}, github_id), do: id != github_id

  defp free_login(%Owner{} = taken, owner) do
    suffix = taken.github_id || taken.id

    from(o in Owner, where: o.id == ^taken.id)
    |> Repo.update_all(set: [login: "#{taken.login}#github-#{suffix}"])

    owner
  end

  @doc """
  Creates or updates a repo from GitHub's data (or a manual add). A repo
  is matched by its GitHub id first, so a rename or transfer updates the
  row, keeping its settings, secrets and environments.
  """
  def upsert_repo(%Owner{} = owner, attrs) do
    full_name = attrs[:full_name] || attrs["full_name"]
    github_id = attrs[:github_id] || attrs["github_id"]
    by_name = Repo.get_by(GitRepo, full_name: full_name)
    by_name = if by_name && other_repo?(by_name, github_id), do: free_name(by_name), else: by_name

    repo =
      case by_github_id(github_id) do
        # Renamed or transferred, unless another row already has the new
        # name (a manual add of it); that one wins.
        %GitRepo{} = repo when is_nil(by_name) or by_name.id == repo.id -> repo
        _ -> by_name || %GitRepo{owner_id: owner.id}
      end

    save_synced_repo(repo, owner, attrs, github_id)
  end

  # An admin checking the name with GitHub can bind this same row after
  # our lookup. Claim the first binding only while the row still names
  # the unbound repo. If the admin won, resolve the name and ID again so
  # a replacement gets its own row, settings and archive status.
  defp save_synced_repo(%GitRepo{id: id, github_id: nil} = repo, owner, attrs, github_id)
       when not is_nil(id) and is_integer(github_id) do
    row = from r in GitRepo, where: r.id == ^id and r.full_name == ^repo.full_name

    Repo.transact(fn ->
      case bind_unbound(row, github_id, []) do
        {1, [bound]} -> save_synced_repo(bound, owner, attrs, github_id)
        {0, _} -> upsert_repo(owner, attrs)
      end
    end)
  end

  defp save_synced_repo(repo, owner, attrs, _github_id) do
    repo
    |> GitRepo.sync_changeset(attrs)
    |> Ecto.Changeset.put_change(:owner_id, owner.id)
    |> Repo.insert_or_update()
  end

  # A row with the same name but another GitHub id is another repo: the
  # first one was renamed or deleted and this one took its name. It
  # mustn't inherit that row's secrets or settings.
  defp other_repo?(%GitRepo{github_id: nil}, _github_id), do: false
  defp other_repo?(%GitRepo{}, nil), do: false
  defp other_repo?(%GitRepo{github_id: id}, github_id), do: id != github_id

  # Moves the old row out of the way (removed, and renamed so the name is
  # free); if its repo still exists under another name, the next sync
  # matches it by id and renames it back.
  defp free_name(%GitRepo{} = repo) do
    from(r in GitRepo, where: r.id == ^repo.id)
    |> Repo.update_all(
      set: [
        full_name: "#{repo.full_name}#github-#{repo.github_id}",
        removed_at: DateTime.utc_now()
      ]
    )

    nil
  end

  defp by_github_id(nil), do: nil

  defp by_github_id(id) do
    from(r in GitRepo, where: r.github_id == ^id, order_by: r.inserted_at, limit: 1)
    |> Repo.one()
  end

  @doc "Marks the owner's synced repos with these GitHub ids archived, which takes them off the list."
  def mark_archived(_owner, []), do: {0, nil}

  def mark_archived(%Owner{id: owner_id}, github_ids) do
    from(r in GitRepo, where: r.owner_id == ^owner_id and r.github_id in ^github_ids)
    |> Repo.update_all(set: [archived: true])
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
      repo = bind_manual_repo(scope.user, repo)
      Audit.log(scope, "repo.add", repo)
      {:ok, Repo.preload(repo, :owner)}
    else
      [_] -> {:error, :invalid_name}
      error -> error
    end
  end

  # Adding a public repo outside the app installation is an existing admin
  # workflow. A verified immutable ID makes it eligible for the public API.
  defp bind_manual_repo(user, repo) do
    with true <- Foreman.GitHub.configured?(),
         {:ok, token} <- Foreman.GitHub.user_token(user),
         {:ok, remote} <- Foreman.GitHub.Client.impl().get_repo(token, repo.full_name),
         true <- observe_manual_repo(repo, remote) do
      Repo.reload!(repo)
    else
      _ -> repo
    end
  end

  @doc "Record archive status for a matching manual repository, binding its GitHub ID on first observation."
  def observe_manual_repo(
        %GitRepo{manual: true, github_id: bound} = repo,
        %{"id" => id, "full_name" => name} = remote
      )
      when is_integer(id) and is_binary(name) and (is_nil(bound) or bound == id) do
    if String.downcase(name) == String.downcase(repo.full_name) do
      row =
        from r in GitRepo, where: r.id == ^repo.id and r.manual and r.full_name == ^repo.full_name

      if is_nil(bound),
        do: record_manual_binding(row, id, remote["archived"]),
        else: record_manual_archive(row, id, remote["archived"])

      true
    else
      false
    end
  end

  def observe_manual_repo(_, _), do: false

  defp record_manual_binding(row, id, archived) do
    changes = if is_boolean(archived), do: [archived: archived], else: []
    {bound, _} = bind_unbound(row, id, changes)
    # An installation sync may have bound the row during the GitHub request.
    if bound == 0, do: record_manual_archive(row, id, archived)
  end

  defp bind_unbound(row, id, changes) do
    now = DateTime.utc_now()
    binding = [github_id: id, github_identity_bound_at: now, updated_at: now]
    unbound = from r in row, where: is_nil(r.github_id), select: r
    Repo.update_all(unbound, set: binding ++ changes)
  end

  defp record_manual_archive(row, id, archived) when is_boolean(archived) do
    row
    |> where([r], r.github_id == ^id and r.archived != ^archived)
    |> Repo.update_all(set: [archived: archived])
  end

  defp record_manual_archive(_, _, _), do: :ok

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

  @doc """
  The extra repos `repo`'s scoped token reaches besides the repo itself:
  its own, then the ones set on its owner for all of the owner's repos.
  """
  def extra_repos(%GitRepo{} = repo) do
    repo = Repo.preload(repo, :owner)
    Enum.uniq(repo.extra_repos ++ repo.owner.extra_repos)
  end

  @doc "Every repo `repo`'s scoped token reaches: the repo, then its `extra_repos/1`."
  def token_repos(%GitRepo{} = repo), do: Enum.uniq([repo.name | extra_repos(repo)])

  @doc """
  Sets the extra repos every one of `owner`'s repos' scoped tokens reach:
  a list of names, or one string of them separated by commas or spaces.
  """
  def update_owner_extra_repos(%Scope{} = scope, %Owner{} = owner, repos)
      when is_binary(repos) or is_list(repos) do
    %{"extra_repos" => repos} = split_list(%{"extra_repos" => repos}, "extra_repos")

    with :ok <- authorize_admin(scope),
         {:ok, owner} <-
           owner |> Owner.extra_repos_changeset(%{extra_repos: repos}) |> Repo.update() do
      Audit.log(scope, "owner.extra_repos", owner, %{"extra_repos" => owner.extra_repos})
      {:ok, owner}
    end
  end

  def update_registry(%Scope{} = scope, %Owner{} = owner, attrs) do
    with :ok <- authorize_admin(scope),
         # Unlogged, like every write of something encrypted: Ecto logs
         # the values a statement was given.
         {:ok, owner} <- owner |> Owner.registry_changeset(attrs) |> Repo.update(log: false) do
      Audit.log(scope, "owner.registry", owner, %{
        "host" => owner.registry_host,
        "username" => owner.registry_username
      })

      {:ok, owner}
    end
  end

  @doc """
  Sets the token `owner`'s environments' attachments are uploaded with
  (`Foreman.Attachments`), once GitHub has said whose it is, or removes
  it when `token` is empty. It is a machine user's fine-grained token
  with no permissions: the upload takes none, and any other kind can do
  more than upload.
  """
  def update_attachment_token(%Scope{} = scope, %Owner{} = owner, token) do
    with :ok <- authorize_admin(scope),
         {:ok, attrs} <- attachment_attrs(String.trim(token || "")),
         # Unlogged: Ecto logs the values a statement was given, and the
         # token is encrypted only on its way into the database.
         {:ok, owner} <-
           owner |> Owner.attachment_changeset(attrs) |> Repo.update(log: false) do
      Audit.log(scope, "owner.attachment_token", owner, %{
        "login" => owner.attachment_login,
        "set" => not is_nil(owner.attachment_token)
      })

      {:ok, owner}
    end
  end

  defp attachment_attrs("") do
    {:ok,
     %{
       attachment_token: nil,
       attachment_login: nil,
       attachment_token_expires_at: nil,
       attachment_checked_at: nil
     }}
  end

  defp attachment_attrs(token) do
    with {:ok, info} <- Foreman.GitHub.check_attachment_token(token) do
      {:ok,
       %{
         attachment_token: token,
         attachment_login: info.login,
         attachment_token_expires_at: info.expires_at,
         attachment_checked_at: DateTime.utc_now()
       }}
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
