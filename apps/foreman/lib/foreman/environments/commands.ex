defmodule Foreman.Environments.Commands do
  @moduledoc """
  Builds the agent command for a queued operation.

  Built when the operation is sent (not when it's queued), so it carries
  the secrets, GitHub token and identity as they are at that moment.
  Returns the command plus extra args to record on the operation (the
  secret hashes it applied, whether it carried a token).
  """

  alias Foreman.{Accounts, Config, GitHub, Prebuilds, Repo, Secrets, Tailscale}
  alias Foreman.Environments.{Environment, WorkloadAccess}
  alias Foreman.Operations.Operation
  alias ForemanProtocol.Command

  require Logger

  @spec build(Operation.t(), Environment.t()) ::
          {:ok, Command.t(), map()} | {:error, String.t() | :unauthorized} | :retry
  def build(%Operation{} = op, %Environment{} = env) do
    with {:ok, cmd, extra, _policy} <- prepare(op, env), do: {:ok, cmd, extra}
  end

  def prepare(op, env) do
    env = Repo.preload(env, [:user, :box, repo: :owner])

    with {:ok, policy} <- WorkloadAccess.authorize(op, env),
         {:ok, cmd, extra} <- build_authorized(op, env, policy),
         :ok <- recheck(op, env, policy) do
      {:ok, cmd, extra, policy}
    end
  end

  # External credential calls can outlive the grant that authorized them.
  defp recheck(op, env, original) do
    case WorkloadAccess.authorize(op, Repo.reload!(env)) do
      {:ok, ^original} -> :ok
      {:ok, _changed} -> :retry
      other -> other
    end
  end

  defp build_authorized(%{action: "connect"} = op, env, _policy) do
    command(
      op,
      "env.connect",
      Map.merge(base(env), %{hook: op.args["hook"], action: op.args["action"]})
    )
  end

  defp build_authorized(op, env, policy) do
    case op.action do
      action when action in ["create", "rebuild", "pull_rebuild"] ->
        up(op, env, policy)

      "start" ->
        with_secrets(env, policy, fn s ->
          payload =
            base(env)
            |> with_start_limits(env)
            |> Map.put(:compose_env, compose_env(s.values))
            |> put_present(:registry_auth, up_registry_auth(env, s))

          command(op, "env.start", payload)
        end)

      "stop" ->
        command(op, "env.stop", with_start_limits(base(env), env))

      action when action in ["suspend", "destroy"] ->
        command(op, "env." <> action, base(env))

      "restart_all" ->
        with_secrets(env, policy, fn s ->
          command(op, "env.restart", restart(env, "all", [], s))
        end)

      # Everything changed since the environment last came up, as of now:
      # secrets can change between the click and the send.
      "restart_affected" ->
        with_secrets(env, policy, fn s ->
          changed =
            Secrets.changed_names(env.applied_secret_hashes, s.hashes)
            |> Enum.concat(op.args["changed"] || [])
            |> Enum.uniq()
            |> Enum.sort()

          command(op, "env.restart", restart(env, "affected", changed, s))
        end)

      "secrets_write" ->
        secrets_write(op, env, policy)

      "git_status" ->
        command(op, "env.git_status", base(env))

      "logs" ->
        command(
          op,
          "env.logs",
          base(env)
          |> put_present(:service, op.args["service"])
          |> Map.put(:tail, op.args["tail"] || 300)
        )
    end
  end

  defp base(env), do: %{env_id: env.id, slug: env.slug}

  defp restart(env, mode, changed, s) do
    base(env)
    |> Map.merge(%{mode: mode, changed: changed, compose_env: compose_env(s.values)})
    |> put_present(:registry_auth, up_registry_auth(env, s))
  end

  defp with_secrets(env, policy, fun) do
    secrets = secrets(env, policy, fn -> elem(github_token(env, policy), 0) end)

    with {:ok, cmd, extra} <- fun.(secrets) do
      {:ok, cmd, Map.put(extra, "secret_hashes", secrets.hashes)}
    end
  end

  # Pull and rebuild is a rebuild that fast-forwards the clone first. A
  # create starts from the box's prebuild of the repo's branch, if it has
  # one the user may start from.
  # Prebuild disks can contain layers fetched with the owner's registry credential.
  # Foreman does not have a complete dependency manifest for these disks.
  defp up_command("create", _env, _token, policy) when not is_nil(policy), do: {"env.create", %{}}

  defp up_command("create", env, token, nil) do
    case prebuild_id(env, token) do
      nil -> {"env.create", %{}}
      prebuild_id -> {"env.create", %{prebuild_id: prebuild_id}}
    end
  end

  defp up_command("rebuild", _env, _token, _policy), do: {"env.rebuild", %{}}
  defp up_command("pull_rebuild", _env, _token, _policy), do: {"env.rebuild", %{pull: true}}

  # A prebuild holds the repo's content (and its extra repos'), cloned with
  # the app's token, so the user's own token has to show it reads all of it
  # first. Without a token, or one GitHub won't say yes to, the environment
  # clones and builds from nothing like any other. Without GitHub (a local
  # git server) there's no one to ask.
  defp prebuild_id(env, token) do
    with %{id: id, repos: repos} <- Prebuilds.ready(env.repo, env.box_id, env.branch) do
      cond do
        not GitHub.configured?() -> id
        is_binary(token) and GitHub.can_read?(token, env.repo, repos) -> id
        true -> nil
      end
    end
  end

  defp up(op, env, policy) do
    # A build shouldn't wait on GitHub: without a token it goes ahead, and
    # the token follows with the next refresh.
    {token, token_notice, token_status} = github_token(env, policy)
    {type, extra} = up_command(op.action, env, token, policy)
    secrets = secrets(env, policy, fn -> token end)
    identity = identity(env, policy)
    features = features(env, policy)

    tags = if Tailscale.configured?(), do: tags(env, policy), else: []

    with :ok <- before_enrollment(env, op, policy),
         {:ok, ts_key} <- tailscale_key(env, op, tags) do
      files =
        file_set(env, secrets, identity, token, token_notice)
        |> put_present("ts-authkey", ts_key)

      payload =
        base(env)
        |> Map.merge(%{
          repo: env.repo.full_name,
          clone_url: "#{Config.git_base_url()}/#{env.repo.full_name}.git",
          branch: env.branch,
          config_path: env.repo.devcontainer_path || ".devcontainer/devcontainer.json",
          files: files,
          compose_env: compose_env(secrets.values),
          limits: limits(env),
          tailscale: %{
            enabled: Tailscale.configured?(),
            tags: tags
          }
        })
        |> put_present(:dotfiles, dotfiles(identity))
        |> put_present(:features, features)
        |> put_present(:registry_auth, secrets.registry_auth)
        |> Map.merge(extra)

      with {:ok, cmd, _} <- command(op, type, payload) do
        {:ok, cmd,
         %{
           "secret_hashes" => secrets.hashes,
           "token" => token != nil,
           "token_retry" => token_status == :unavailable
         }}
      end
    end
  end

  # The agent replaces the whole set of files. When GitHub can't give a
  # new token just now, the files still go (a box after a reboot needs its
  # secrets more than its token), and an agent on protocol 2 is told to
  # keep the token it has; one on protocol 1 loses it until the next
  # refresh, which this puts first in line. (An expired login is
  # different: that token is dead, and the notice says to sign in again.)
  defp secrets_write(op, env, policy) do
    {token, notice, status} = github_token(env, policy)
    secrets = secrets(env, policy, fn -> token end)
    identity = identity(env, policy)

    payload =
      %{env_id: env.id, files: file_set(env, secrets, identity, token, notice)}
      |> put_present(:keep, keep_token(env, status, policy))

    with {:ok, cmd, _} <- command(op, "env.secrets.write", payload) do
      {:ok, cmd, %{"token" => token != nil, "token_retry" => status == :unavailable}}
    end
  end

  defp keep_token(%{box: %{protocol_version: v}}, :unavailable, nil)
       when is_integer(v) and v >= 2,
       do: ["github-token"]

  defp keep_token(_env, _status, _policy), do: nil

  defp command(op, type, payload) do
    case Command.new(type, payload, op_id: op.id) do
      {:ok, cmd} -> {:ok, cmd, %{}}
      {:error, errors} -> {:error, "couldn't build #{type}: #{inspect(errors)}"}
    end
  end

  # Compose interpolates with these, so the agent's own tools run with
  # them too. A secret stored before its name was reserved still reaches
  # the environment's shells through secrets.env, but not the box.
  defp compose_env(values),
    do: Map.reject(values, fn {name, _} -> ForemanProtocol.Schema.reserved_env?(name) end)

  defp identity(_env, %{principal: %{kind: :service_account}}),
    do: %{git_name: nil, git_email: nil, dotfiles_repository: nil}

  defp identity(env, _policy), do: Accounts.effective_identity(env.user, env.repo)

  defp tags(_env, %{tags: tags}), do: tags
  defp tags(env, _policy), do: Tailscale.tags_for(env.repo, env.user)

  defp secrets(env, %{secret_ids: ids}, _get_token) do
    values = Secrets.resolve(env, approved_ids: ids)
    %{values: values, hashes: Secrets.hashes(values), registry_auth: nil}
  end

  defp secrets(env, policy, get_token) do
    shared? = share_credentials?(env, get_token)
    values = Secrets.resolve(env, include_shared: shared?)
    auth = if shared? and is_nil(policy), do: registry_auth(env.repo.owner)
    %{values: values, hashes: Secrets.hashes(values), registry_auth: auth}
  end

  defp share_credentials?(env, get_token) do
    cond do
      not GitHub.configured?() ->
        true

      is_nil(env.repo.owner.registry_token) and not Secrets.shared?(env) ->
        false

      true ->
        token = get_token.()
        is_binary(token) and GitHub.can_read?(token, env.repo, [])
    end
  end

  defp file_set(env, secrets, identity, token, token_notice) do
    %{
      "secrets.env" => Secrets.render_env_file(secrets.values),
      "gitconfig" => gitconfig(identity),
      "notices" => notices(env, secrets, token_notice)
    }
    |> put_present("github-token", token)
  end

  @doc false
  def gitconfig(identity) do
    lines =
      [
        identity.git_name && "\tname = \"#{identity.git_name}\"",
        identity.git_email && "\temail = \"#{identity.git_email}\""
      ]
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> ""
      lines -> "# Managed by Foreman.\n[user]\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp notices(env, secrets, token_notice) do
    changed = Secrets.changed_names(env.applied_secret_hashes, secrets.hashes)

    pending =
      if env.created_once and changed != [],
        do:
          "Foreman: secrets changed (#{Enum.join(changed, ", ")}). New shells have them; restart the environment to apply them to running processes.\n"

    [pending, token_notice] |> Enum.reject(&is_nil/1) |> Enum.join()
  end

  # {token, notice, status}: status is :ok, :expired (sign in again) or
  # :unavailable (GitHub failed this time; try again later).
  defp github_token(env, policy) do
    if GitHub.configured?() do
      case workload_token(env, policy) do
        {:ok, token} ->
          {token, nil, :ok}

        {:error, :login_expired} ->
          {nil,
           "Foreman: your GitHub login expired, so git push and gh won't work here. Sign in to Foreman again to fix it.\n",
           :expired}

        {:error, reason} ->
          Logger.warning("couldn't get a GitHub token for #{env.slug}: #{inspect(reason)}")

          {nil,
           "Foreman: couldn't get a GitHub token for this environment just now, so git push and gh won't work yet. Foreman will try again shortly.\n",
           :unavailable}
      end
    else
      {nil, nil, :ok}
    end
  end

  defp workload_token(env, nil), do: GitHub.environment_token(env.user, env.repo)

  defp workload_token(env, policy),
    do: GitHub.workload_token(policy.principal, env.repo, policy.repository_ids)

  defp before_enrollment(env, op, policy) do
    if Tailscale.configured?(), do: recheck(op, env, policy), else: :ok
  end

  # A new node needs an auth key on its first boot only; the node's state
  # volume keeps its identity after that. A rebuild can also be the first
  # boot with Tailscale enabled. A failed build drops its
  # key (keys expire after a day), so the next attempt gets a fresh one.
  defp tailscale_key(env, %Operation{action: action, status: status}, tags)
       when action == "create" or
              (action in ["rebuild", "pull_rebuild"] and is_nil(env.tailscale_device_id)) do
    cond do
      not Tailscale.configured?() ->
        {:ok, nil}

      # Reconnects resend the same operation. A newly queued build can
      # inherit an expired key from an older control plane's failed build.
      env.ts_authkey && status in ["dispatched", "running"] && env.ts_authkey_tags == tags ->
        {:ok, env.ts_authkey}

      true ->
        case Tailscale.create_auth_key(env, tags) do
          {:ok, %{key: key}} ->
            {:ok, key}

          {:error, reason} ->
            {:error, "couldn't create a Tailscale auth key: #{inspect(reason)}"}
        end
    end
  end

  defp tailscale_key(_env, _op, _tags), do: {:ok, nil}

  defp with_start_limits(payload, %{box: %{protocol_version: v}} = env)
       when is_integer(v) and v >= 7,
       do: Map.put(payload, :limits, limits(env))

  defp with_start_limits(payload, _env), do: payload

  defp limits(env) do
    %{}
    |> put_present(:cpus, env.cpu_limit || env.repo.cpu_limit)
    |> put_present(:memory_mb, env.memory_limit_mb || env.repo.memory_limit_mb)
  end

  defp dotfiles(%{dotfiles_repository: nil}), do: nil

  defp dotfiles(identity) do
    %{repository: identity.dotfiles_repository}
    |> put_present(:install_command, identity.dotfiles_install_command)
    |> put_present(:target_path, identity.dotfiles_target_path)
  end

  # Protocol 3. An older agent would refuse the whole command, so its
  # environments build without them until it updates.
  defp features(_env, %{principal: %{kind: :service_account}}), do: %{}

  defp features(%{box: %{protocol_version: v}} = env, _policy) when is_integer(v) and v >= 3,
    do: Accounts.effective_features(env.user, env.repo)

  defp features(_env, _policy), do: %{}

  defp registry_auth(%{registry_token: token} = owner) when is_binary(token) do
    [%{host: owner.registry_host || "ghcr.io", username: owner.registry_username, token: token}]
  end

  defp registry_auth(_), do: nil

  # A start or restart runs devcontainer up too, which resolves the repo's
  # features again. Protocol 4: an older agent refuses the field there.
  defp up_registry_auth(%{box: %{protocol_version: v}}, secrets) when is_integer(v) and v >= 4,
    do: secrets.registry_auth

  defp up_registry_auth(_env, _secrets), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, _key, value) when value == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
