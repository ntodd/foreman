defmodule Foreman.Environments.Commands do
  @moduledoc """
  Builds the agent command for a queued operation.

  Built when the operation is sent (not when it's queued), so it carries
  the secrets, GitHub token and identity as they are at that moment.
  Returns the command plus extra args to record on the operation (the
  secret hashes it applied, whether it carried a token).
  """

  alias Foreman.{Accounts, Config, GitHub, Repo, Secrets, Tailscale}
  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation
  alias ForemanProtocol.Command

  require Logger

  @spec build(Operation.t(), Environment.t()) :: {:ok, Command.t(), map()} | {:error, String.t()}
  def build(%Operation{action: "connect"} = op, %Environment{} = env) do
    command(
      op,
      "env.connect",
      Map.merge(base(env), %{hook: op.args["hook"], action: op.args["action"]})
    )
  end

  def build(%Operation{} = op, %Environment{} = env) do
    env = Repo.preload(env, [:user, :box, repo: :owner])

    case op.action do
      action when action in ["create", "rebuild", "pull_rebuild"] ->
        up(op, env)

      "start" ->
        with_secrets(env, fn s ->
          command(op, "env.start", base(env) |> Map.put(:compose_env, s.values))
        end)

      "stop" ->
        command(op, "env.stop", base(env))

      "destroy" ->
        command(op, "env.destroy", base(env))

      "restart_all" ->
        with_secrets(env, fn s -> command(op, "env.restart", restart(env, "all", [], s)) end)

      # Everything changed since the environment last came up, as of now:
      # secrets can change between the click and the send.
      "restart_affected" ->
        with_secrets(env, fn s ->
          changed =
            Secrets.changed_names(env.applied_secret_hashes, s.hashes)
            |> Enum.concat(op.args["changed"] || [])
            |> Enum.uniq()
            |> Enum.sort()

          command(op, "env.restart", restart(env, "affected", changed, s))
        end)

      "secrets_write" ->
        secrets_write(op, env)

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

  defp restart(env, mode, changed, s),
    do: base(env) |> Map.merge(%{mode: mode, changed: changed, compose_env: s.values})

  defp with_secrets(env, fun) do
    secrets = secrets(env)

    with {:ok, cmd, extra} <- fun.(secrets) do
      {:ok, cmd, Map.put(extra, "secret_hashes", secrets.hashes)}
    end
  end

  # Pull and rebuild is a rebuild that fast-forwards the clone first.
  defp up_command("create"), do: {"env.create", %{}}
  defp up_command("rebuild"), do: {"env.rebuild", %{}}
  defp up_command("pull_rebuild"), do: {"env.rebuild", %{pull: true}}

  defp up(op, env) do
    {type, extra} = up_command(op.action)
    secrets = secrets(env)
    identity = Accounts.effective_identity(env.user, env.repo)
    features = features(env)
    # A build shouldn't wait on GitHub: without a token it goes ahead, and
    # the token follows with the next refresh.
    {token, token_notice, token_status} = github_token(env)

    with {:ok, ts_key, env} <- tailscale_key(env, op.action) do
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
          compose_env: secrets.values,
          limits: limits(env),
          tailscale: %{
            enabled: Tailscale.configured?(),
            tags:
              if(Tailscale.configured?(), do: Tailscale.tags_for(env.repo, env.user), else: [])
          }
        })
        |> put_present(:dotfiles, dotfiles(identity))
        |> put_present(:features, features)
        |> put_present(:registry_auth, registry_auth(env.repo.owner))
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
  defp secrets_write(op, env) do
    secrets = secrets(env)
    identity = Accounts.effective_identity(env.user, env.repo)
    {token, notice, status} = github_token(env)

    payload =
      %{env_id: env.id, files: file_set(env, secrets, identity, token, notice)}
      |> put_present(:keep, keep_token(env, status))

    with {:ok, cmd, _} <- command(op, "env.secrets.write", payload) do
      {:ok, cmd, %{"token" => token != nil, "token_retry" => status == :unavailable}}
    end
  end

  defp keep_token(%{box: %{protocol_version: v}}, :unavailable) when is_integer(v) and v >= 2,
    do: ["github-token"]

  defp keep_token(_env, _status), do: nil

  defp command(op, type, payload) do
    case Command.new(type, payload, op_id: op.id) do
      {:ok, cmd} -> {:ok, cmd, %{}}
      {:error, errors} -> {:error, "couldn't build #{type}: #{inspect(errors)}"}
    end
  end

  defp secrets(env) do
    values = Secrets.resolve(env)
    %{values: values, hashes: Secrets.hashes(values)}
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
  defp github_token(env) do
    if GitHub.configured?() do
      case GitHub.environment_token(env.user, env.repo) do
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

  # A new node needs an auth key on its first boot only; the node's state
  # volume keeps its identity after that.
  defp tailscale_key(env, "create") do
    cond do
      not Tailscale.configured?() ->
        {:ok, nil, env}

      env.ts_authkey ->
        {:ok, env.ts_authkey, env}

      true ->
        case Tailscale.create_auth_key(env, env.repo, env.user) do
          {:ok, %{key: key}} ->
            env = env |> Environment.state_changeset(%{ts_authkey: key}) |> Repo.update!()
            {:ok, key, env}

          {:error, reason} ->
            {:error, "couldn't create a Tailscale auth key: #{inspect(reason)}"}
        end
    end
  end

  defp tailscale_key(env, _action), do: {:ok, env.ts_authkey, env}

  defp limits(env) do
    %{}
    |> put_present(:cpus, env.cpu_limit || env.repo.cpu_limit)
    |> put_present(:memory_mb, env.memory_limit_mb || env.repo.memory_limit_mb)
  end

  defp dotfiles(%{dotfiles_repository: nil}), do: nil

  defp dotfiles(identity) do
    put_present(
      %{repository: identity.dotfiles_repository},
      :install_command,
      identity.dotfiles_install_command
    )
  end

  # Protocol 3. An older agent would refuse the whole command, so its
  # environments build without them until it updates.
  defp features(%{box: %{protocol_version: v}} = env) when is_integer(v) and v >= 3,
    do: Accounts.effective_features(env.user, env.repo)

  defp features(_env), do: %{}

  defp registry_auth(%{registry_token: token} = owner) when is_binary(token) do
    [%{host: owner.registry_host || "ghcr.io", username: owner.registry_username, token: token}]
  end

  defp registry_auth(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, _key, value) when value == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
