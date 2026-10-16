defmodule Foreman.GitHub do
  @moduledoc """
  The GitHub App: sign-in, user tokens, the tokens environments get, repo
  sync and devcontainer detection, the manifest flow that creates the app,
  and registry credential checks.

  ## Environment tokens

  By default an environment gets the user's token narrowed with
  `POST /applications/{client_id}/token/scoped` to its repo (plus any
  extra repos configured) and the repo's permissions. Scoped tokens act
  as the user, so pushes and PRs are theirs, and they can't be refreshed:
  Foreman re-scopes a fresh parent token every few hours. A repo set to
  `broad` gets the user's unscoped token instead.

  User tokens last 8 hours; refresh tokens 6 months and are single use.
  Refreshes for a user are serialized so two can't burn the same refresh
  token, and run in their own process so a caller that dies mid-refresh
  (a closed tab) can't lose the rotated token.
  """

  alias Foreman.{Accounts, Repos, Settings}
  alias Foreman.Accounts.User
  alias Foreman.GitHub.Client

  require Logger

  @refresh_margin 300

  # Environments get a new token when theirs is four hours old (checked
  # every 30 minutes), so the one they get has to last longer than that.
  @environment_token_life 5 * 3600

  @doc false
  def environment_token_life, do: @environment_token_life

  defp client, do: Client.impl()

  # -- app config --------------------------------------------------------------

  @doc "The GitHub App's credentials, from the environment or the manifest flow. nil until set up."
  def app do
    env = Application.get_env(:foreman, :github_app, %{})

    cond do
      present?(env[:client_id]) and present?(env[:client_secret]) and present?(env[:private_key]) ->
        Map.put_new(env, :slug, nil)

      stored = Settings.get("github_app") ->
        %{
          app_id: stored["id"],
          slug: stored["slug"],
          client_id: stored["client_id"],
          client_secret: stored["client_secret"],
          private_key: stored["pem"],
          html_url: stored["html_url"]
        }

      true ->
        nil
    end
  end

  def configured?, do: app() != nil

  defp present?(value), do: is_binary(value) and value != ""

  # -- sign-in -------------------------------------------------------------------

  @doc "Returns `{url, verifier}`: GitHub's authorize URL (with PKCE) and the verifier to keep in the session."
  def authorize_url(state, redirect_uri) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    query =
      URI.encode_query(%{
        "client_id" => app().client_id,
        "redirect_uri" => redirect_uri,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "allow_signup" => "false"
      })

    {"https://github.com/login/oauth/authorize?" <> query, verifier}
  end

  @doc "Finishes sign-in: trades the code for tokens and signs the user in."
  def complete_sign_in(code, verifier, redirect_uri) do
    app = app()
    config = Accounts.login_config()

    with {:ok, tokens} <- client().exchange_code(app, code, verifier, redirect_uri),
         {:ok, profile} <- client().get_user(tokens.access_token) do
      org_member? =
        config.allowed_org != nil and
          client().org_membership(tokens.access_token, config.allowed_org) == {:ok, true}

      Accounts.sign_in_from_github(profile, tokens, config: config, org_member?: org_member?)
    end
  end

  # -- user and environment tokens -------------------------------------------------

  @doc """
  A current access token for `user`, refreshing it when it has less than
  `min_life` seconds left (five minutes by default).
  `{:error, :login_expired}` means the refresh token is gone or rejected
  and the user has to sign in again.
  """
  def user_token(%User{id: user_id}, min_life \\ @refresh_margin) do
    # GitHub spends the old refresh token as soon as it answers, so the
    # refresh runs unlinked: if the caller dies, it still stores the new one.
    callers = [self() | Process.get(:"$callers", [])]
    ref = make_ref()
    caller = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        {result, rotated?} = locked_user_token(user_id, min_life)
        # Outside the lock: pushing to environments asks for tokens.
        if rotated?, do: push_rotated_token(user_id)
        send(caller, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Logger.error("GitHub token refresh crashed: #{inspect(reason)}")
        {:error, :refresh_failed}
    end
  end

  defp locked_user_token(user_id, min_life) do
    :global.trans({{__MODULE__, :refresh, user_id}, self()}, fn ->
      user = Accounts.get_user!(user_id)

      cond do
        fresh?(user, min_life) -> {{:ok, user.access_token}, false}
        is_nil(user.refresh_token) -> {{:error, :login_expired}, false}
        true -> refresh(user)
      end
    end)
  end

  # GitHub revokes the old token when it's refreshed, and other
  # environments of the user may hold it.
  defp push_rotated_token(user_id) do
    %{user_id: user_id} |> Foreman.Jobs.PushTokens.new() |> Oban.insert()
  rescue
    error -> Logger.error("couldn't queue a token push for #{user_id}: #{inspect(error)}")
  end

  defp fresh?(%User{access_token: nil}, _min_life), do: false
  defp fresh?(%User{access_token_expires_at: nil}, _min_life), do: true

  defp fresh?(%User{access_token_expires_at: expires}, min_life) do
    DateTime.diff(expires, DateTime.utc_now()) > min_life
  end

  defp refresh(user) do
    case client().refresh_user_token(app(), user.refresh_token) do
      {:ok, tokens} ->
        {:ok, user} = Accounts.update_tokens(user, tokens)
        result = recheck_access(user)
        {result, match?({:ok, _}, result)}

      {:error, :bad_refresh_token} ->
        {login_expired(user), false}

      {:error, reason} ->
        {{:error, reason}, false}
    end
  end

  @doc """
  Checks that a signed-in user may still use Foreman, for users who don't
  refresh a token often enough to be checked that way. A token that needs
  refreshing is refreshed, which checks; otherwise the current one is used.
  """
  def check_access(%User{} = user) do
    if fresh?(user, @refresh_margin) do
      recheck_access(user)
    else
      user_token(user)
    end
  end

  # Who may use Foreman can change after sign-in (someone leaves the org
  # or an allowlist), so every refresh checks again with the new token.
  # Only a definite "no" ends their access; a GitHub error changes nothing.
  defp recheck_access(user) do
    config = Accounts.login_config()

    verdict =
      case Accounts.access(user, config) do
        :ask_org -> org_verdict(user, config.allowed_org)
        verdict -> verdict
      end

    if verdict == :denied do
      Logger.warning("#{user.login} may no longer use Foreman; ending their sessions")
      :ok = Accounts.revoke_access(user, "no longer allowed at token refresh")
      {:error, :login_expired}
    else
      {:ok, user.access_token}
    end
  end

  defp org_verdict(user, org) do
    case client().org_membership(user.access_token, org) do
      {:ok, true} ->
        :allowed

      {:ok, false} ->
        :denied

      {:error, reason} ->
        Logger.warning("couldn't check #{user.login}'s membership of #{org}: #{inspect(reason)}")
        :allowed
    end
  end

  defp login_expired(user) do
    case Accounts.mark_github_login_expired(user) do
      :ok ->
        Logger.warning(
          "GitHub refresh token for #{user.login} was rejected; they need to sign in again"
        )

        Phoenix.PubSub.broadcast(Foreman.PubSub, "user:#{user.id}", :github_login_expired)
        {:error, :login_expired}

      # They signed in again while the refresh was in flight.
      :stale ->
        case Accounts.get_user!(user.id) do
          %User{access_token: token} when is_binary(token) -> {:ok, token}
          _ -> {:error, :login_expired}
        end
    end
  end

  @doc """
  The GitHub token for an environment of `repo` owned by `user`: scoped to
  the repo (and its extra repos) by default, the user's own token when the
  repo is set to `broad`. The token lasts until the environment's next
  scheduled one.
  """
  def environment_token(%User{} = user, %Repos.Repo{} = repo) do
    repo = Foreman.Repo.preload(repo, :owner)

    with {:ok, token} <- user_token(user, @environment_token_life) do
      case repo.token_mode do
        "broad" ->
          {:ok, token}

        _scoped ->
          repos = Enum.uniq([repo.name | repo.extra_repos])
          permissions = Repos.Repo.permissions(repo)

          with {:ok, %{token: scoped}} <-
                 client().scope_user_token(app(), token, repo.owner.login, repos, permissions) do
            {:ok, scoped}
          end
      end
    end
  end

  def list_branches(%User{} = user, %Repos.Repo{} = repo) do
    with {:ok, token} <- user_token(user) do
      client().list_branches(token, repo.full_name)
    end
  end

  # -- repo sync -----------------------------------------------------------------

  @doc """
  Syncs owners and repos from every installation of the app, and checks
  each repo for a devcontainer. Repos no longer in an installation, and
  those of owners that uninstalled the app, are marked removed.
  """
  def sync_repos do
    app = app()

    with {:ok, installations} <- client().list_installations(app) do
      results =
        for installation <- installations do
          account = installation["account"]

          {:ok, owner} =
            Repos.upsert_owner(%{
              login: account["login"],
              kind: account["type"],
              github_id: account["id"],
              installation_id: installation["id"]
            })

          sync_installation(app, owner, installation["id"])
        end

      installed = MapSet.new(installations, & &1["id"])

      for owner <- Repos.list_owners(),
          owner.installation_id && owner.installation_id not in installed,
          do: Repos.mark_removed(owner, [])

      {:ok, results |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
    end
  end

  defp sync_installation(app, owner, installation_id) do
    with {:ok, token} <- client().installation_token(app, installation_id),
         {:ok, repos} <- client().list_installation_repos(token) do
      for data <- repos, not data["archived"] do
        Repos.upsert_repo(
          owner,
          %{
            full_name: data["full_name"],
            name: data["name"],
            github_id: data["id"],
            default_branch: data["default_branch"] || "main",
            private: data["private"],
            archived: data["archived"] || false,
            removed_at: nil
          }
          |> Map.merge(devcontainer_attrs(token, data["full_name"], owner.login))
        )
      end

      Repos.mark_removed(owner, Enum.map(repos, & &1["id"]))
      {:ok, length(repos)}
    else
      error ->
        Logger.warning("syncing #{owner.login} failed: #{inspect(error)}")
        {:error, 0}
    end
  end

  # When GitHub couldn't say (rate limits, outages), the repo keeps what
  # the last sync found rather than looking like it has no devcontainer.
  defp devcontainer_attrs(token, full_name, owner_login) do
    case detect_devcontainer(token, full_name, owner_login) do
      {:error, reason} ->
        Logger.warning("couldn't check #{full_name} for a devcontainer: #{inspect(reason)}")
        %{}

      attrs ->
        Map.put(attrs, :devcontainer_checked_at, DateTime.utc_now())
    end
  end

  @config_candidates [".devcontainer/devcontainer.json", ".devcontainer.json"]

  @doc """
  Finds a repo's devcontainer config and reads what Foreman needs from it:
  `hostRequirements` and any private registry images or features under
  the repo's owner on ghcr.io. `{:error, reason}` when GitHub failed to
  answer, as opposed to the repo having no devcontainer.
  """
  def detect_devcontainer(token, full_name, owner_login) do
    with {:ok, nested} <- nested_configs(token, full_name),
         {:ok, found} <- find_config(token, full_name, @config_candidates ++ nested) do
      devcontainer_fields(found, owner_login)
    end
  end

  defp find_config(token, full_name, candidates) do
    Enum.reduce_while(candidates, {:ok, nil}, fn path, acc ->
      case client().get_file(token, full_name, path, nil) do
        {:ok, content} -> {:halt, {:ok, {path, content}}}
        {:error, :not_found} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp devcontainer_fields(found, owner_login) do
    case found do
      nil ->
        %{
          devcontainer_path: nil,
          host_requirements: nil,
          private_registry_refs: [],
          devcontainer_error: nil
        }

      {path, content} ->
        case ForemanProtocol.Jsonc.decode(content) do
          {:ok, config} ->
            %{
              devcontainer_path: path,
              host_requirements: config["hostRequirements"],
              private_registry_refs: registry_refs(config, owner_login),
              devcontainer_error:
                if(config["dockerComposeFile"], do: nil, else: "not a compose-based devcontainer")
            }

          {:error, message} ->
            %{
              devcontainer_path: path,
              devcontainer_error: message,
              host_requirements: nil,
              private_registry_refs: []
            }
        end
    end
  end

  defp nested_configs(token, full_name) do
    case client().list_dir(token, full_name, ".devcontainer") do
      {:ok, entries} ->
        {:ok,
         for(
           %{"type" => "dir", "name" => name} <- entries,
           do: ".devcontainer/#{name}/devcontainer.json"
         )}

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def registry_refs(config, owner_login) do
    owner = String.downcase(owner_login)
    features = config |> Map.get("features", %{}) |> Map.keys()
    image = List.wrap(config["image"])

    (features ++ image)
    |> Enum.filter(&String.starts_with?(String.downcase(&1), "ghcr.io/#{owner}/"))
    |> Enum.uniq()
  end

  # -- manifest flow -------------------------------------------------------------

  @doc """
  The manifest for creating Foreman's GitHub App in one click
  (https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest).
  """
  def manifest(base_url, name) do
    %{
      "name" => name,
      "url" => base_url,
      "redirect_url" => base_url <> "/setup/github/created",
      "callback_urls" => [base_url <> "/auth/github/callback"],
      "setup_url" => base_url <> "/setup/github/installed",
      "public" => false,
      "request_oauth_on_install" => false,
      "hook_attributes" => %{"url" => base_url <> "/github/webhook", "active" => false},
      "default_permissions" => %{
        "contents" => "write",
        "pull_requests" => "write",
        "issues" => "write",
        "metadata" => "read",
        "members" => "read",
        "workflows" => "write"
      },
      "default_events" => []
    }
  end

  @doc "Exchanges the manifest flow's code for the new app's credentials and stores them (encrypted)."
  def complete_manifest(code) do
    with {:ok, app} <- client().convert_manifest(code) do
      Settings.put(
        "github_app",
        Map.take(app, ~w(id slug client_id client_secret pem webhook_secret html_url))
      )

      {:ok, app}
    end
  end

  # -- registry credentials -------------------------------------------------------

  @doc """
  Checks a machine user's classic PAT for pulling from `host`: it must
  have `read:packages`, and every private image or feature the owner's
  repos reference must be pullable with it.
  """
  def check_registry_credential(host, username, token, refs) do
    with {:ok, info} <- client().check_classic_token(token),
         :ok <- require_scope(info.scopes) do
      failures =
        for ref <- refs,
            result = client().check_registry_pull(host, username, token, ref),
            result != :ok do
          "#{ref}: #{inspect(result)}"
        end

      case failures do
        [] -> {:ok, info}
        failures -> {:error, "can't pull " <> Enum.join(failures, "; ")}
      end
    else
      {:error, :invalid_token} -> {:error, "GitHub rejected the token"}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, other} -> {:error, "couldn't check the token: #{inspect(other)}"}
    end
  end

  defp require_scope(scopes) do
    if "read:packages" in scopes or "write:packages" in scopes,
      do: :ok,
      else:
        {:error, "the token needs the read:packages scope (it has: #{Enum.join(scopes, ", ")})"}
  end
end
