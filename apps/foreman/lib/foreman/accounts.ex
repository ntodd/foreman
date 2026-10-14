defmodule Foreman.Accounts do
  @moduledoc """
  Users, sign-in and sessions, and each user's git identity and dotfiles.

  Users sign in with GitHub (the GitHub App's user OAuth flow). Who may
  sign in is set by config: `FOREMAN_ADMINS`, `FOREMAN_ALLOWED_USERS`
  and `FOREMAN_ALLOWED_ORG`. With none of those set, the first person to
  sign in becomes the admin and nobody else gets in.
  """
  import Ecto.Query

  alias Foreman.Accounts.{RepoSetting, Session, User}
  alias Foreman.{Audit, Repo, Scope}

  @session_days 30

  # -- users ---------------------------------------------------------------

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)
  def get_user_by_login(login), do: Repo.get_by(User, login: login)

  def list_users, do: User |> order_by(:login) |> Repo.all()

  def login_config do
    %{
      admins: Application.get_env(:foreman, :admins, []),
      allowed_users: Application.get_env(:foreman, :allowed_users, []),
      allowed_org: Application.get_env(:foreman, :allowed_org)
    }
  end

  @doc """
  Signs a GitHub user in, creating or updating their record and storing
  their tokens. `org_member?` says whether they're an active member of
  the allowed org (the caller asks GitHub).
  """
  @spec sign_in_from_github(map(), map(), keyword()) ::
          {:ok, User.t()} | {:error, :not_allowed | :disabled | Ecto.Changeset.t()}
  def sign_in_from_github(profile, tokens, opts) do
    config = Keyword.get_lazy(opts, :config, &login_config/0)
    org_member? = Keyword.get(opts, :org_member?, false)
    login = profile["login"]
    existing = Repo.get_by(User, github_id: profile["id"]) || Repo.get_by(User, login: login)

    cond do
      existing && existing.disabled_at ->
        {:error, :disabled}

      not allowed?(login, existing, config, org_member?) ->
        {:error, :not_allowed}

      true ->
        attrs =
          Map.merge(token_attrs(tokens), %{
            github_id: profile["id"],
            login: login,
            name: profile["name"],
            avatar_url: profile["avatar_url"],
            github_login_expired: false
          })

        result =
          (existing || %User{role: initial_role(login, config)})
          |> User.github_changeset(attrs)
          |> Ecto.Changeset.change(role: role_for(existing, login, config))
          |> Repo.insert_or_update()

        with {:ok, user} <- result do
          Audit.log(user, "user.sign_in", user)
          {:ok, user}
        end
    end
  end

  defp allowed?(login, existing, config, org_member?) do
    cond do
      login in config.admins ->
        true

      login in config.allowed_users ->
        true

      config.allowed_org && org_member? ->
        true

      config.admins == [] and config.allowed_users == [] and is_nil(config.allowed_org) ->
        existing != nil or no_users?()

      true ->
        existing != nil and existing.role == "admin"
    end
  end

  defp no_users?, do: not Repo.exists?(User)

  defp initial_role(login, config) do
    cond do
      login in config.admins ->
        "admin"

      config.admins == [] and not Repo.exists?(from u in User, where: u.role == "admin") ->
        "admin"

      true ->
        "member"
    end
  end

  # Configured admins are always admins; otherwise a user keeps the role
  # an admin gave them.
  defp role_for(nil, login, config), do: initial_role(login, config)

  defp role_for(%User{role: role}, login, config),
    do: if(login in config.admins, do: "admin", else: role)

  defp token_attrs(tokens) do
    now = DateTime.utc_now()

    %{
      access_token: tokens[:access_token],
      access_token_expires_at: tokens[:expires_in] && DateTime.add(now, tokens[:expires_in]),
      refresh_token: tokens[:refresh_token],
      refresh_token_expires_at:
        tokens[:refresh_token_expires_in] && DateTime.add(now, tokens[:refresh_token_expires_in])
    }
  end

  @doc "Stores refreshed GitHub tokens."
  def update_tokens(%User{} = user, tokens) do
    user
    |> User.github_changeset(Map.put(token_attrs(tokens), :github_login_expired, false))
    |> Repo.update()
  end

  @doc "Marks a user's GitHub login as expired: their refresh token no longer works."
  def mark_github_login_expired(%User{} = user) do
    user
    |> Ecto.Changeset.change(github_login_expired: true, access_token: nil, refresh_token: nil)
    |> Repo.update()
  end

  def update_preferences(%Scope{user: user}, attrs) do
    with {:ok, user} <- user |> User.preferences_changeset(attrs) |> Repo.update() do
      Audit.log(user, "user.preferences", user)
      {:ok, user}
    end
  end

  def change_preferences(%User{} = user, attrs \\ %{}),
    do: User.preferences_changeset(user, attrs)

  def set_role(%Scope{} = scope, %User{} = user, role) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      scope.user.id == user.id -> {:error, :self}
      true -> update_role(scope, user, %{role: role})
    end
  end

  def set_disabled(%Scope{} = scope, %User{} = user, disabled?) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      scope.user.id == user.id -> {:error, :self}
      true -> update_role(scope, user, %{disabled_at: if(disabled?, do: DateTime.utc_now())})
    end
  end

  defp update_role(scope, user, attrs) do
    with {:ok, updated} <- user |> User.role_changeset(attrs) |> Repo.update() do
      if updated.disabled_at, do: delete_user_sessions(updated)
      Audit.log(scope, "user.role", updated, Map.new(attrs, fn {k, v} -> {k, to_string(v)} end))
      {:ok, updated}
    end
  end

  # -- sessions --------------------------------------------------------------

  @doc "Creates a session and returns its token. Only the token's hash is stored."
  def create_session(%User{} = user, user_agent) do
    raw = :crypto.strong_rand_bytes(32)

    Repo.insert!(%Session{
      user_id: user.id,
      token_hash: :crypto.hash(:sha256, raw),
      user_agent: user_agent && String.slice(user_agent, 0, 255),
      last_seen_at: DateTime.utc_now()
    })

    Base.url_encode64(raw, padding: false)
  end

  def get_user_by_session(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} ->
        cutoff = DateTime.add(DateTime.utc_now(), -@session_days * 86_400)

        from(s in Session,
          join: u in assoc(s, :user),
          where:
            s.token_hash == ^:crypto.hash(:sha256, raw) and s.inserted_at > ^cutoff and
              is_nil(u.disabled_at),
          select: u
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  def get_user_by_session(_), do: nil

  def delete_session(token) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false) do
      Repo.delete_all(from s in Session, where: s.token_hash == ^:crypto.hash(:sha256, raw))
    end

    :ok
  end

  def delete_session(_), do: :ok

  def delete_user_sessions(%User{id: id}) do
    Repo.delete_all(from s in Session, where: s.user_id == ^id)
    :ok
  end

  # -- per-repo identity -----------------------------------------------------

  def get_repo_setting(%User{id: user_id}, %{id: repo_id}) do
    Repo.get_by(RepoSetting, user_id: user_id, repo_id: repo_id)
  end

  def put_repo_setting(%Scope{user: user}, repo, attrs) do
    setting = get_repo_setting(user, repo) || %RepoSetting{user_id: user.id, repo_id: repo.id}

    with {:ok, setting} <- setting |> RepoSetting.changeset(attrs) |> Repo.insert_or_update() do
      Audit.log(user, "user.repo_settings", {"Repo", repo.id})
      {:ok, setting}
    end
  end

  @doc """
  The git identity and dotfiles an environment of `repo` gets: the user's
  per-repo override where set, otherwise their default.
  """
  def effective_identity(%User{} = user, repo) do
    setting = get_repo_setting(user, repo) || %RepoSetting{}

    for field <- [:git_name, :git_email, :dotfiles_repository, :dotfiles_install_command],
        into: %{} do
      {field, blank_to_nil(Map.get(setting, field)) || blank_to_nil(Map.get(user, field))}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
