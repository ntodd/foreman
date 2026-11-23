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

  def get_user!(id), do: Repo.get!(User, id) |> effective_user()
  def get_user(id), do: Repo.get(User, id) |> effective_user()
  def get_user_by_login(login), do: Repo.get_by(User, login: login) |> effective_user()

  def list_users,
    do:
      User
      |> where([u], not u.service_account)
      |> order_by(:login)
      |> Repo.all()
      |> Enum.map(&effective_user/1)

  @doc "Fetch the effective human administrator under the actor row lock for a mutation."
  def lock_admin(%Scope{user: %User{} = actor}) do
    with %User{role: "admin", disabled_at: nil, service_account: false} = current <-
           effective_user(Repo.one_for_update(from u in User, where: u.id == ^actor.id)),
         true <- actor.access_generation == current.access_generation,
         verdict <- access(current),
         true <- verdict == :allowed or (verdict == :ask_org and not current.github_login_expired) do
      {:ok, Scope.for_user(current)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def lock_admin(_scope), do: {:error, :unauthorized}

  def login_config do
    %{
      admins: Application.get_env(:foreman, :admins, []),
      allowed_users: Application.get_env(:foreman, :allowed_users, []),
      allowed_org: Application.get_env(:foreman, :allowed_org)
    }
  end

  @doc """
  Signs a GitHub user in, creating or updating their record and storing
  their tokens. Capture the identity generation before asking GitHub about
  org membership, then compare it under the same lock used for offboarding.
  A new callback after confirmed loss can obtain a fresh membership decision.
  """
  @spec sign_in_from_github(map(), map(), keyword()) ::
          {:ok, User.t()}
          | {:error, :not_allowed | :disabled | :access_changed | Ecto.Changeset.t()}
  def sign_in_from_github(profile, tokens, opts) do
    config = Keyword.get_lazy(opts, :config, &login_config/0)
    existing = find_github_user(profile, &Repo.one/1)
    first_sign_in = if is_nil(existing), do: begin_first_sign_in(profile["id"])

    membership =
      case opts[:check_membership] do
        nil -> Keyword.get(opts, :org_member?, false)
        check -> check.(config.allowed_org)
      end

    result =
      Repo.transact(fn ->
        # Serialize callbacks for the same new identity before looking for
        # a user. A different callback may have created one while we waited.
        first_current? = first_sign_in_current?(first_sign_in)
        current = find_github_user(profile, &Repo.one_for_update/1)

        if first_current? and same_sign_in_generation?(existing, current, profile["id"]) and
             config == Keyword.get_lazy(opts, :config, &login_config/0) do
          checked_sign_in(current, profile, tokens, config, membership)
        else
          {:error, :access_changed}
        end
      end)

    # Confirmed loss must commit even though the sign-in is refused.
    case result do
      {:ok, :not_allowed} -> {:error, :not_allowed}
      result -> notify_role_change(result, existing)
    end
  end

  defp same_sign_in_generation?(nil, nil, _), do: true

  # A concurrent first admission creates generation zero. A negative
  # decision still has to revoke that user's newly issued credentials.
  defp same_sign_in_generation?(nil, %User{github_id: id, access_generation: 0}, id), do: true

  defp same_sign_in_generation?(
         %User{id: id, access_generation: g},
         %User{id: id, access_generation: g},
         _
       ),
       do: true

  defp same_sign_in_generation?(_, _, _), do: false

  # An unknown GitHub identity has no user row to lock. Keep only its
  # immutable GitHub ID and a counter, so a denial never provisions a user.
  defp begin_first_sign_in(github_id) do
    Repo.insert_all("github_sign_in_generations", [%{github_id: github_id}],
      on_conflict: :nothing,
      conflict_target: [:github_id]
    )

    query = first_sign_in_generation(github_id)
    {query, Repo.one!(query)}
  end

  defp first_sign_in_generation(github_id) do
    from g in "github_sign_in_generations", where: g.github_id == ^github_id, select: g.generation
  end

  defp first_sign_in_current?(nil), do: true
  defp first_sign_in_current?({query, generation}), do: Repo.one_for_update(query) == generation

  defp checked_sign_in(current, profile, tokens, config, membership) do
    login = profile["login"]

    cond do
      String.starts_with?(login, "service:") or (current && current.service_account) ->
        {:error, :not_allowed}

      current && current.disabled_at ->
        {:error, :disabled}

      allowed?(login, current, config, membership) ->
        persist_sign_in(current, profile, tokens, config)

      true ->
        if membership != :unknown, do: revoke_sign_in(current, profile)

        {:ok, :not_allowed}
    end
  end

  defp revoke_sign_in(nil, %{"id" => github_id}),
    do: Repo.update_all(first_sign_in_generation(github_id), inc: [generation: 1])

  defp revoke_sign_in(current, _profile),
    do: revoke_access(current, "no longer allowed at sign-in")

  defp persist_sign_in(current, profile, tokens, config) do
    login = profile["login"]
    release_login(login, profile["id"])

    attrs =
      Map.merge(token_attrs(tokens), %{
        github_id: profile["id"],
        login: login,
        name: profile["name"],
        avatar_url: profile["avatar_url"],
        github_login_expired: false
      })

    changeset =
      (current || %User{})
      |> User.github_changeset(attrs)
      |> Ecto.Changeset.change(role_attrs(current, login, config))

    with {:ok, user} <- Repo.insert_or_update(changeset) do
      Audit.log(user, "user.sign_in", user)
      {:ok, user}
    end
  end

  defp notify_role_change({:ok, user} = result, %User{role: old_role})
       when old_role != user.role do
    disconnect_live_views(user)
    result
  end

  defp notify_role_change(result, _existing), do: result

  # GitHub logins can be renamed and then taken by someone else, so a
  # login only identifies a record that has no GitHub id yet.
  defp find_github_user(%{"id" => github_id, "login" => login}, fetch) do
    fetch.(from u in User, where: u.github_id == ^github_id) ||
      fetch.(
        from u in User, where: not u.service_account and u.login == ^login and is_nil(u.github_id)
      )
  end

  # Another account held this login before a rename on GitHub. Its record
  # keeps its GitHub id and gets a placeholder login until its owner signs
  # in under their new name.
  defp release_login(login, github_id) do
    from(u in User, where: u.login == ^login and u.github_id != ^github_id)
    |> Repo.all()
    |> Enum.each(fn stale ->
      stale |> Ecto.Changeset.change(login: "#{login}-#{stale.github_id}") |> Repo.update!()
    end)
  end

  # Everyone has to be configured or in the allowed org. Admins promoted
  # in the UI count as configured while neither FOREMAN_ADMINS nor an org
  # is set (the UI is where admins are managed then); with an org, leaving
  # it ends an admin's access like anyone else's.
  # With nothing configured, the first person claims the deployment and
  # only existing users get back in.
  defp allowed?(login, existing, config, org_member?) do
    cond do
      listed?(login, config, org_member?) -> true
      ui_admin?(existing, config) -> true
      unconfigured?(config) -> existing != nil or no_users?()
      true -> false
    end
  end

  defp listed?(login, config, org_member?) do
    listed_in?(login, config.admins) or listed_in?(login, config.allowed_users) or
      (config.allowed_org != nil and org_member? == true)
  end

  # GitHub logins aren't case-sensitive, and the configured lists are
  # typed by hand.
  defp listed_in?(login, list) do
    login = String.downcase(login)
    Enum.any?(list, &(String.downcase(&1) == login))
  end

  defp ui_admin?(existing, config) do
    config.admins == [] and is_nil(config.allowed_org) and
      match?(%User{role: "admin", admin_via_config: false}, existing)
  end

  defp unconfigured?(config),
    do: config.admins == [] and config.allowed_users == [] and is_nil(config.allowed_org)

  defp no_users?, do: not Repo.exists?(User)

  @doc """
  Whether a signed-in user may still use Foreman, by the same rule as
  sign-in: `:allowed`, `:denied`, or `:ask_org` when it comes down to
  whether they're still an active member of the allowed org.
  """
  @spec access(User.t(), map()) :: :allowed | :denied | :ask_org
  def access(%User{} = user, config \\ login_config()) do
    cond do
      user.service_account or not is_nil(user.disabled_at) -> :denied
      allowed?(user.login, user, config, false) -> :allowed
      config.allowed_org -> :ask_org
      true -> :denied
    end
  end

  @doc """
  Ends a user's access after they've left the org or an allowlist: their
  sessions and open pages end, and their GitHub tokens are dropped so
  their environments stop getting new ones. The account isn't disabled;
  if they're let back in, they sign in again as before.
  """
  def revoke_access(%User{id: id} = user, reason) do
    {:ok, :revoked} =
      Repo.transact(fn ->
        from(u in User, where: u.id == ^id)
        |> Repo.update_all(
          inc: [access_generation: 1],
          set: [
            github_login_expired: true,
            access_token: nil,
            refresh_token: nil,
            updated_at: DateTime.utc_now()
          ]
        )

        delete_user_sessions(user)
        Foreman.OAuth.revoke_user(id)
        Audit.log(nil, "user.access_revoked", user, %{"reason" => reason})
        {:ok, :revoked}
      end)

    disconnect_live_views(user)
    :ok
  end

  def configured_admin?(login), do: listed_in?(login, login_config().admins)

  defp role_attrs(existing, login, config) do
    cond do
      match?(%User{role: "admin", admin_via_config: false}, existing) ->
        %{role: "admin", admin_via_config: false}

      listed_in?(login, config.admins) ->
        %{role: "admin", admin_via_config: true}

      is_nil(existing) and unconfigured?(config) and no_users?() ->
        %{role: "admin", admin_via_config: false}

      true ->
        %{role: "member", admin_via_config: false}
    end
  end

  # A session may be read immediately after a configuration change, before
  # the periodic access check has updated the stored role.
  defp effective_user(%User{admin_via_config: true} = user) do
    if configured_admin?(user.login), do: user, else: %{user | role: "member"}
  end

  defp effective_user(user), do: user

  @doc "Remove grants whose login is no longer in FOREMAN_ADMINS and refresh open pages."
  def revoke_removed_config_admins(config) do
    admins = Enum.map(config.admins, &String.downcase/1)

    query =
      from u in User,
        where: u.admin_via_config and fragment("lower(?)", u.login) not in ^admins,
        select: u.id

    {_, ids} = Repo.update_all(query, set: [role: "member", admin_via_config: false])
    Enum.each(ids, &disconnect_live_views(%User{id: &1}))
  end

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
    Repo.transact(fn ->
      current = Repo.one_for_update(from u in User, where: u.id == ^user.id)

      cond do
        current.disabled_at || current.service_account ->
          {:error, :login_expired}

        current.access_generation != user.access_generation or
            current.refresh_token != user.refresh_token ->
          {:error, :stale_token}

        true ->
          current
          |> User.github_changeset(Map.put(token_attrs(tokens), :github_login_expired, false))
          |> Repo.update()
      end
    end)
  end

  @doc """
  Marks a user's GitHub login as expired: their refresh token no longer
  works. Returns `:stale` without changing anything if the record changed
  since `user` was read (they signed in again meanwhile), so fresh tokens
  aren't wiped.
  """
  def mark_github_login_expired(%User{id: id, updated_at: updated_at}) do
    {count, _} =
      from(u in User, where: u.id == ^id and u.updated_at == ^updated_at)
      |> Repo.update_all(
        set: [
          github_login_expired: true,
          access_token: nil,
          refresh_token: nil,
          updated_at: DateTime.utc_now()
        ]
      )

    if count == 1, do: :ok, else: :stale
  end

  def update_preferences(%Scope{user: user}, attrs) do
    with {:ok, user} <- user |> User.preferences_changeset(attrs) |> Repo.update() do
      Audit.log(user, "user.preferences", user)
      {:ok, user}
    end
  end

  @doc """
  Replaces the devcontainer features that go on all the user's
  environments. The audit log records which refs changed, not their
  options, which can hold anything.
  """
  def update_features(%Scope{user: user}, features) do
    changeset = User.features_changeset(user, features)

    with {:ok, updated} <- Repo.update(changeset) do
      if changeset.changes != %{} do
        Audit.log(user, "user.features", updated, feature_changes(user, updated))
      end

      {:ok, updated}
    end
  end

  defp feature_changes(%{devcontainer_features: old}, %{devcontainer_features: new}) do
    old = old || %{}

    %{
      "added" => new |> Map.keys() |> Enum.reject(&Map.has_key?(old, &1)) |> Enum.sort(),
      "removed" => old |> Map.keys() |> Enum.reject(&Map.has_key?(new, &1)) |> Enum.sort(),
      "changed" =>
        for({ref, opts} <- new, Map.has_key?(old, ref), old[ref] != opts, do: ref) |> Enum.sort()
    }
  end

  def change_preferences(%User{} = user, attrs \\ %{}),
    do: User.preferences_changeset(user, attrs)

  def set_role(%Scope{} = scope, %User{} = user, role) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      user.service_account -> {:error, :unauthorized}
      scope.user.id == user.id -> {:error, :self}
      configured_admin?(user.login) -> {:error, :configured_admin}
      true -> update_role(scope, Repo.reload!(user), %{role: role, admin_via_config: false})
    end
  end

  def set_disabled(%Scope{} = scope, %User{} = user, disabled?) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      user.service_account -> {:error, :unauthorized}
      scope.user.id == user.id -> {:error, :self}
      true -> update_role(scope, user, %{disabled_at: if(disabled?, do: DateTime.utc_now())})
    end
  end

  defp update_role(scope, user, attrs) do
    result =
      Repo.transact(fn ->
        current = Repo.one_for_update(from u in User, where: u.id == ^user.id)
        changeset = User.role_changeset(current, attrs)

        changeset =
          if attrs[:disabled_at] do
            Ecto.Changeset.change(changeset,
              access_generation: current.access_generation + 1,
              access_token: nil,
              refresh_token: nil,
              github_login_expired: true
            )
          else
            changeset
          end

        with {:ok, updated} <- Repo.update(changeset) do
          if updated.disabled_at do
            delete_user_sessions(updated)
            Foreman.OAuth.revoke_user(updated.id)
          end

          Audit.log(
            scope,
            "user.role",
            updated,
            Map.new(attrs, fn {k, v} -> {k, to_string(v)} end)
          )

          {:ok, updated}
        end
      end)

    if match?({:ok, _}, result), do: disconnect_live_views(user)
    result
  end

  # Open LiveViews hold the scope they mounted with. `:access_changed`
  # makes each one reload its page (see `ForemanWeb.UserAuth`), and the
  # disconnect drops the sockets too, so they come back with the user's
  # current role, or not at all.
  defp disconnect_live_views(%User{id: id}) do
    Phoenix.PubSub.broadcast(Foreman.PubSub, "user:#{id}", :access_changed)
    Phoenix.Channel.Server.broadcast(Foreman.PubSub, "user_sessions:#{id}", "disconnect", %{})
  end

  # -- sessions --------------------------------------------------------------

  @doc "Creates a session and returns its token. Only the token's hash is stored."
  def create_session(%User{service_account: true}, _user_agent), do: nil

  def create_session(%User{service_account: false} = user, user_agent) do
    {:ok, token} =
      Repo.transact(fn ->
        case Repo.one_for_update(from u in User, where: u.id == ^user.id) do
          %User{
            service_account: false,
            disabled_at: nil,
            github_login_expired: false,
            access_generation: generation
          }
          when generation == user.access_generation ->
            {:ok, insert_session(user, user_agent)}

          _ ->
            {:ok, nil}
        end
      end)

    token
  end

  defp insert_session(user, user_agent) do
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
              is_nil(u.disabled_at) and not u.service_account,
          select: u
        )
        |> Repo.one()
        |> effective_user()

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

    for field <- [
          :git_name,
          :git_email,
          :dotfiles_repository,
          :dotfiles_install_command,
          :dotfiles_target_path
        ],
        into: %{} do
      {field, blank_to_nil(Map.get(setting, field)) || blank_to_nil(Map.get(user, field))}
    end
  end

  @doc """
  The user's own devcontainer features for an environment of `repo`: all
  of them, less the ones they've turned off for the repo.
  """
  def effective_features(%User{} = user, repo) do
    disabled =
      case get_repo_setting(user, repo) do
        %RepoSetting{disabled_features: disabled} -> disabled || []
        nil -> []
      end

    Map.reject(user.devcontainer_features || %{}, fn {ref, _} ->
      ForemanProtocol.Feature.base(ref) in disabled
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
