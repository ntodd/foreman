defmodule ForemanAgent.Env do
  @moduledoc """
  Environment operations on this box.

  Layout, per environment:

      <envs_root>/<env_id>/workspace/<repo>   the clone (bind-mounted into the containers)
      <envs_root>/<env_id>/meta/              overlay, override config, saved spec (agent only)
      <secrets_root>/<env_id>/                secrets files (tmpfs, mounted at /run/foreman)

  The workspace is writable from inside the environment, so everything the
  agent reads or writes there goes through `ForemanAgent.SafeFS`, the
  compose config is re-checked by `ForemanAgent.Env.Policy` on every start,
  and git status runs inside the container rather than on the box.

  `run/3` takes a validated command payload and a context:

      %{config: %Config{}, runner: module, docker: module, log: fn stream, data -> ... end}
  """

  alias ForemanAgent.Config
  alias ForemanAgent.Env.{Affected, ComposeScan, Overlay, Policy}
  alias ForemanAgent.SafeFS
  alias ForemanProtocol.{Feature, Jsonc}

  require Logger

  @secret_mode 0o600
  @max_config_bytes 1_048_576
  @feature_ref "./.foreman/feature"

  # A hung docker, compose or git would otherwise hold the environment's
  # queue until the agent restarts. Builds get the longest.
  @command_timeout :timer.minutes(30)
  @clone_timeout :timer.minutes(60)
  # Under the control plane's three-hour cutoff, so the agent's own
  # message is the one people see.
  @up_timeout :timer.minutes(165)
  @logs_timeout :timer.minutes(5)
  @tailscale_timeout :timer.seconds(15)
  @join_poll 500

  # A start or restart rebuilds a container built with an older Foreman
  # feature than this, since a reused container keeps the old feature.
  # 1.1.0 dropped NET_ADMIN and NET_RAW.
  @feature_floor "1.1.0"

  @type ctx :: %{
          config: ForemanAgent.Config.t(),
          runner: module(),
          docker: module(),
          log: function()
        }

  # The three-element error carries a result with it: a refused pull says
  # so, since the environment is still as it was.
  @spec run(String.t(), map(), ctx()) ::
          {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def run("env.create", p, ctx), do: up(p, ctx, rebuild: false)
  def run("env.rebuild", p, ctx), do: up(p, ctx, rebuild: true)
  def run("env.start", p, ctx), do: start(p, ctx, node_id: true)
  def run("env.stop", p, ctx), do: stop(p, ctx)
  def run("env.restart", p, ctx), do: restart(p, ctx)
  def run("env.destroy", p, ctx), do: destroy(p, ctx)

  def run("env.secrets.write", p, ctx),
    do: write_secrets(paths(ctx.config, p.env_id), p.files, Map.get(p, :keep, []))

  def run("env.logs", p, ctx), do: logs(p, ctx)
  def run("env.git_status", p, ctx), do: git_status(p, ctx)

  # -- paths ---------------------------------------------------------------

  @doc false
  def paths(config, env_id, repo \\ nil) do
    env_dir = Path.join(config.envs_root, env_id)

    %{
      env_dir: env_dir,
      workspace: Path.join(env_dir, "workspace"),
      clone: repo && Path.join([env_dir, "workspace", repo |> String.split("/") |> List.last()]),
      meta: Path.join(env_dir, "meta"),
      secrets: Path.join(config.secrets_root, env_id)
    }
  end

  # -- create / rebuild / start --------------------------------------------

  defp up(p, ctx, opts) do
    paths = paths(ctx.config, p.env_id, p.repo)
    spec = Map.drop(p, [:files, :compose_env, :registry_auth, :pull])
    # A clone this rebuild makes is already up to date.
    pull? = Map.get(p, :pull) == true and File.exists?(spec_path(paths))

    with :ok <- check_clone_url(p.clone_url, ctx.config),
         :ok <- ensure_dirs(paths),
         {:ok, _} <- write_secrets(paths, p.files),
         :ok <- ensure_clone(paths, p, ctx),
         :ok <- if(pull?, do: pull(p, ctx), else: :ok),
         {:ok, prepared} <- prepare(paths, spec, p.compose_env, ctx),
         {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, opts) do
      save_spec(paths, spec, prepared, result)
      {:ok, put_node_id(result, spec, ctx)}
    end
  end

  defp start(p, ctx, opts \\ []) do
    with {:ok, spec} <- load_spec(ctx.config, p.env_id) do
      paths = paths(ctx.config, p.env_id, spec.repo)
      ensure_secrets_dir(paths)

      with {:ok, prepared} <- prepare(paths, spec, p.compose_env, ctx),
           {:ok, rebuild} <- feature_rebuild(ctx, p.env_id, prepared, opts),
           {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, rebuild: rebuild) do
        save_spec(paths, spec, prepared, result)
        {:ok, if(opts[:node_id], do: put_node_id(result, spec, ctx), else: result)}
      end
    end
  end

  # The control plane deletes exactly this device when the environment is
  # destroyed; another deployment on the tailnet can have a device with
  # the same hostname. The node joins in the background once the
  # container starts (tailscale-up.sh), so this waits a little for it.
  defp put_node_id(%{"container_id" => container} = result, %{tailscale: %{enabled: true}}, ctx)
       when is_binary(container) do
    deadline = System.monotonic_time(:millisecond) + ctx.config.tailscale_join_wait

    case await_node_id(ctx, container, deadline) do
      nil ->
        ctx.log.(
          "info",
          "The environment hasn't joined the tailnet yet; see /var/log/foreman-tailscale.log in the container\n"
        )

        result

      id ->
        Map.put(result, "tailscale_node_id", id)
    end
  end

  defp put_node_id(result, _spec, _ctx), do: result

  defp await_node_id(ctx, container, deadline) do
    with nil <- node_id(ctx, container) do
      left = deadline - System.monotonic_time(:millisecond)

      if left > 0 do
        Process.sleep(min(@join_poll, left))
        await_node_id(ctx, container, deadline)
      end
    end
  end

  # As root, which tailscaled's socket wants. What the container says is
  # the repo's to decide, so only an ID-shaped answer is taken.
  defp node_id(ctx, container) do
    args =
      ["exec", "-u", "0", container, "tailscale", "--socket=/var/run/tailscale/tailscaled.sock"] ++
        ["status", "--json", "--peers=false"]

    with {:ok, output} <-
           cmd(ctx, ctx.config.docker, args,
             env: %{},
             quiet: true,
             timeout: @tailscale_timeout,
             label: "tailscale status"
           ),
         {:ok, %{"BackendState" => "Running", "Self" => %{"ID" => id}}} when is_binary(id) <-
           JSON.decode(output),
         true <- id =~ ~r/\A[A-Za-z0-9]{1,64}\z/ do
      id
    else
      _ -> nil
    end
  end

  defp check_clone_url(url, config) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)
    port_host = if uri.port in [80, 443, nil], do: host, else: "#{host}:#{uri.port}"

    cond do
      host not in config.allowed_git_hosts and port_host not in config.allowed_git_hosts ->
        {:error,
         "cloning from #{host} isn't allowed on this box (allowed: #{Enum.join(config.allowed_git_hosts, ", ")})"}

      uri.scheme != "https" and host not in config.insecure_git_hosts and
          port_host not in config.insecure_git_hosts ->
        {:error, "#{host} must be cloned over https"}

      true ->
        :ok
    end
  end

  defp ensure_dirs(paths) do
    with :ok <- mkdir(paths.env_dir, 0o700),
         :ok <- mkdir(paths.workspace, 0o755),
         :ok <- mkdir(paths.meta, 0o700) do
      ensure_secrets_dir(paths)
    end
  end

  defp ensure_secrets_dir(paths), do: mkdir(paths.secrets, 0o700)

  defp mkdir(path, mode) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, mode)
  end

  # -- secrets -------------------------------------------------------------

  # Files missing from `files` are removed, except those named in `keep`
  # (a GitHub token the control plane couldn't renew just now).
  defp write_secrets(paths, files, keep \\ []) do
    with :ok <- ensure_secrets_dir(paths) do
      results =
        for name <- ForemanProtocol.Schema.secret_files() do
          path = Path.join(paths.secrets, name)

          case Map.fetch(files, name) do
            {:ok, content} -> SafeFS.write_atomic(path, content, @secret_mode)
            :error -> remove_unless_kept(path, name in keep)
          end
        end

      kept = keep |> Enum.reject(&Map.has_key?(files, &1)) |> Enum.sort()

      case Enum.find(results, &(&1 != :ok)) do
        nil -> {:ok, %{"files" => files |> Map.keys() |> Enum.sort(), "kept" => kept}}
        {:error, reason} -> {:error, "couldn't write secrets: #{inspect(reason)}"}
      end
    end
  end

  defp remove_unless_kept(_path, true), do: :ok
  defp remove_unless_kept(path, false), do: rm_quiet(path)

  defp rm_quiet(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  # -- clone ---------------------------------------------------------------

  # A clone is kept once the environment has come up (it holds the
  # developer's work). Before that, a retry clones again, so a fix pushed
  # after a failed create is picked up.
  defp ensure_clone(paths, p, ctx) do
    if File.dir?(Path.join(paths.clone, ".git")) and File.exists?(spec_path(paths)) do
      :ok
    else
      with :ok <- discard_failed_attempt(paths, p, ctx), do: clone(paths, p, ctx)
    end
  end

  # What an earlier attempt left behind. Its containers mount the old
  # clone, so they go too; volumes stay. git never runs in the old clone:
  # anything in the environment could have rewritten its .git/config.
  defp discard_failed_attempt(paths, p, ctx) do
    if File.exists?(paths.clone) do
      ctx.log.("info", "Discarding the clone from an earlier attempt\n")

      with {:ok, _} <- compose(ctx, p.slug, ["down", "--remove-orphans"]) do
        remove_in(ctx, paths.workspace, Path.basename(paths.clone))
      end
    else
      :ok
    end
  end

  defp clone(paths, p, ctx) do
    helper = write_credential_helper(paths)

    args =
      [
        "-c",
        "credential.helper=",
        "-c",
        "credential.helper=" <> helper,
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "protocol.allow=never",
        "-c",
        "protocol.https.allow=always"
      ] ++
        http_protocol(p.clone_url) ++
        ["clone", "--progress", "--branch", p.branch, "--", p.clone_url, paths.clone]

    ctx.log.("info", "Cloning #{p.repo} (#{p.branch})\n")

    case cmd(ctx, ctx.config.git, args, env: %{}, label: "git clone", timeout: @clone_timeout) do
      {:ok, _} -> :ok
      {:error, output} -> {:error, "git clone failed: #{last_lines(output)}"}
    end
  end

  defp http_protocol("http://" <> _), do: ["-c", "protocol.http.allow=always"]
  defp http_protocol(_), do: []

  # A git credential helper that reads the token file at call time, so the
  # token never appears in argv, the URL or .git/config.
  defp write_credential_helper(paths) do
    path = Path.join(paths.meta, "git-credential")
    token = Path.join(paths.secrets, "github-token")

    script = """
    #!/bin/sh
    [ "$1" = get ] || exit 0
    host=; protocol=
    while IFS='=' read -r key value; do
      [ -z "$key" ] && break
      case "$key" in host) host=$value ;; protocol) protocol=$value ;; esac
    done
    [ "$protocol" = https ] && [ "$host" = github.com ] && [ -s '#{token}' ] || exit 0
    printf 'username=x-access-token\\npassword=%s\\n' "$(cat '#{token}')"
    """

    :ok = SafeFS.write_atomic(path, script, 0o700)
    path
  end

  # -- pull ----------------------------------------------------------------

  # Fast-forwards the clone to its branch, before anything is torn down,
  # so a refusal leaves the environment running as it was. git runs in
  # the devcontainer, as the remote user with the environment's own
  # credential helper: on the box it would read a .git/config anything in
  # the environment can rewrite.
  defp pull(p, ctx) do
    with {:ok, spec, container} <- running_devcontainer(p, ctx) do
      ctx.log.("info", "Pulling #{p.branch}\n")
      git = &container_git(ctx, spec, container, &1, &2, &3)

      case fast_forward(git, p.branch) do
        :ok -> :ok
        {:error, message} -> {:error, message, %{"pull_failed" => true}}
      end
    end
  end

  defp running_devcontainer(p, ctx) do
    with {:ok, spec} <- load_spec(ctx.config, p.env_id) do
      case devcontainer_container(ctx, p.env_id, spec.devcontainer_service) do
        {:ok, container} ->
          {:ok, spec, container}

        {:error, _} ->
          ctx.log.("info", "Starting the environment to pull\n")

          # The rebuild after the pull updates the feature; a refused pull
          # leaves the container as it was.
          with {:ok, _} <- start(p, ctx, feature_rebuild: false),
               {:ok, spec} <- load_spec(ctx.config, p.env_id),
               {:ok, container} <-
                 devcontainer_container(ctx, p.env_id, spec.devcontainer_service) do
            {:ok, spec, container}
          end
      end
    end
  end

  defp fast_forward(git, branch) do
    with :ok <- on_branch(git, branch),
         :ok <- no_changes(git),
         :ok <- fetch(git, branch),
         :ok <- no_local_commits(git, branch) do
      # git overwrites ignored files by default: a local .env the branch
      # has started tracking would be lost.
      case git.(["merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"], "git merge",
             quiet: false
           ) do
        {:ok, _} ->
          :ok

        {:error, output} ->
          {:error, "couldn't fast-forward to origin/#{branch}: #{last_lines(output)}"}
      end
    end
  end

  defp on_branch(git, branch) do
    case git.(["symbolic-ref", "--short", "-q", "HEAD"], "git symbolic-ref", []) do
      {:ok, out} ->
        case String.trim(out) do
          ^branch ->
            :ok

          other ->
            {:error,
             "the clone has #{other} checked out, not #{branch}; switch back to #{branch} first"}
        end

      {:error, _} ->
        {:error, "the clone isn't on a branch (detached HEAD); check out #{branch} first"}
    end
  end

  # Untracked files don't stop a fast-forward; git says so if one would
  # be overwritten.
  defp no_changes(git) do
    case git.(["status", "--porcelain=v1", "--untracked-files=no"], "git status", []) do
      {:ok, out} ->
        case out |> String.split("\n", trim: true) |> length() do
          0 -> :ok
          1 -> {:error, "1 changed file in the workspace; commit or stash it first"}
          n -> {:error, "#{n} changed files in the workspace; commit or stash them first"}
        end

      {:error, output} ->
        {:error, "git status failed: #{last_lines(output)}"}
    end
  end

  defp fetch(git, branch) do
    case git.(["fetch", "--no-tags", "origin", branch], "git fetch", quiet: false) do
      {:ok, _} -> :ok
      {:error, output} -> {:error, "git fetch failed: #{last_lines(output)}"}
    end
  end

  defp no_local_commits(git, branch) do
    case git.(["rev-list", "--count", "FETCH_HEAD..HEAD"], "git rev-list", []) do
      {:ok, out} ->
        case Integer.parse(String.trim(out)) do
          {0, ""} ->
            :ok

          {1, ""} ->
            {:error,
             "the clone has 1 commit that isn't on origin/#{branch}; push or rebase it first"}

          {n, ""} ->
            {:error,
             "the clone has #{n} commits that aren't on origin/#{branch}; push or rebase them first"}

          _ ->
            {:error, "git rev-list gave something other than a count"}
        end

      {:error, output} ->
        {:error, "git rev-list failed: #{last_lines(output)}"}
    end
  end

  # -- prepare -------------------------------------------------------------

  # Every profile is checked: the CLI starts the services runServices
  # names, and compose starts a profiled service it's asked for by name.
  @check_args [profiles: :all]

  defp prepare(paths, spec, compose_env, ctx) do
    config_dir = config_dir(spec.config_path)
    files_config = &compose_config(ctx, spec.slug, &1, &2, paths.meta, @check_args)

    with {:ok, config} <- read_devcontainer(paths.clone, spec.config_path),
         {:ok, features} <- user_features(spec, config, ctx),
         {:ok, rel_files, service} <- compose_spec(config),
         {:ok, compose_files} <- resolve_compose_files(paths.clone, config_dir, rel_files),
         {:ok, scan_warnings} <- scan_compose(paths, compose_files, spec, ctx.config),
         env = compose_env(ctx, spec.slug, compose_env),
         {:ok, base} <- files_config.(compose_files, env),
         services = base |> Map.get("services", %{}) |> Map.keys() |> Enum.sort(),
         :ok <- check_service(service, services),
         :ok <- check_run_services(config["runServices"], services),
         overlay_path = Path.join(paths.meta, "overlay.yml"),
         :ok <- write_overlay(overlay_path, paths, spec, services, service, base, ctx),
         {:ok, merged} <- files_config.(compose_files ++ [overlay_path], env),
         {:ok, docker} <- docker_info(ctx),
         {:ok, policy_warnings} <- check_policy(merged, config, paths, spec, ctx.config, docker),
         {:ok, docker_warnings} <- check_docker(docker, paths, spec, ctx.config),
         warnings = Enum.uniq(scan_warnings ++ policy_warnings ++ docker_warnings),
         override_path = Path.join(paths.meta, "devcontainer.json"),
         :ok <- write_override(override_path, config, compose_files, overlay_path),
         :ok <- install_feature(paths.clone, config_dir, ctx) do
      Enum.each(warnings, &ctx.log.("info", "Warning: #{&1}\n"))

      {:ok,
       %{
         config: config,
         compose_files: compose_files,
         overlay_path: overlay_path,
         override_path: override_path,
         services: services,
         devcontainer_service: service,
         features: features,
         gpus: Policy.requests_gpus?(merged),
         networks: network_names_in(merged),
         warnings: warnings
       }}
    end
  end

  # The features a user adds to their own environments, less any the repo
  # already declares at whatever version: the repo's copy is the one that
  # installs. None can take the Foreman feature's id. The CLI lowercases
  # refs, so a repo's are compared that way (a user's already are).
  defp user_features(spec, config, ctx) do
    features = Map.get(spec, :features, %{})
    declared = declared_features(config["features"])

    case Enum.find(Map.keys(features), &(Feature.id(&1) == Feature.foreman_id())) do
      nil ->
        {skipped, kept} =
          Enum.split_with(features, fn {ref, _} -> Feature.base(ref) in declared end)

        for {ref, _} <- skipped do
          ctx.log.("info", "Skipping your feature #{ref}: the repo already declares it\n")
        end

        {:ok, Map.new(kept)}

      ref ->
        {:error,
         "your feature #{ref} (from your Foreman settings) uses the id of Foreman's own feature; remove it"}
    end
  end

  defp declared_features(features) when is_map(features),
    do: MapSet.new(Map.keys(features), &(&1 |> String.downcase() |> Feature.base()))

  defp declared_features(_), do: MapSet.new()

  defp read_devcontainer(clone, rel) do
    case SafeFS.read(clone, rel, max_bytes: @max_config_bytes) do
      {:ok, content} ->
        case Jsonc.decode(content) do
          {:ok, config} -> {:ok, config}
          {:error, message} -> {:error, "#{rel}: #{message}"}
        end

      {:error, :enoent} ->
        {:error, "#{rel} not found in the repository"}

      {:error, :escapes_root} ->
        {:error, "#{rel} points outside the repository"}

      {:error, reason} ->
        {:error, "couldn't read #{rel}: #{inspect(reason)}"}
    end
  end

  defp compose_spec(%{"dockerComposeFile" => files, "service" => service})
       when is_binary(service) and (is_binary(files) or is_list(files)) do
    files = List.wrap(files)

    if files != [] and Enum.all?(files, &is_binary/1),
      do: {:ok, files, service},
      else: {:error, "dockerComposeFile must be a path or a list of paths"}
  end

  defp compose_spec(_config) do
    {:error, "Foreman needs a compose-based devcontainer (dockerComposeFile and service)"}
  end

  defp resolve_compose_files(clone, config_dir, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      rel = if Path.type(file) == :absolute, do: file, else: Path.join(config_dir, file)

      case SafeFS.resolve(clone, rel) do
        {:ok, path} -> {:cont, {:ok, acc ++ [path]}}
        {:error, :enoent} -> {:halt, {:error, "compose file #{file} not found"}}
        {:error, _} -> {:halt, {:error, "compose file #{file} is outside the repository"}}
      end
    end)
  end

  # The devcontainer.json at the repo root lives in "."; everything is
  # joined relative to the clone.
  defp config_dir(config_path) do
    case Path.dirname(config_path) do
      "." -> ""
      dir -> dir
    end
  end

  defp check_service(service, services) do
    if service in services,
      do: :ok,
      else: {:error, "devcontainer service '#{service}' isn't defined in the compose files"}
  end

  defp check_run_services(nil, _services), do: :ok

  defp check_run_services(run_services, services) when is_list(run_services) do
    case Enum.reject(run_services, &(&1 in services)) do
      [] ->
        :ok

      missing ->
        {:error, "runServices names #{Enum.join(missing, ", ")}, not in the compose files"}
    end
  end

  defp check_run_services(_, _services), do: {:error, "runServices must be a list of services"}

  defp compose_config(ctx, slug, files, env, meta, opts) do
    out = Path.join(meta, "compose-config.json")
    profiles = if opts[:profiles] == :all, do: ["--profile", "*"], else: []

    args =
      ["compose", "-p", slug] ++
        profiles ++
        Enum.flat_map(files, &["-f", &1]) ++
        ["config"] ++ Keyword.get(opts, :extra, []) ++ ["--format", "json", "-o", out]

    result =
      case cmd(ctx, ctx.config.docker, args,
             env: env,
             quiet: true,
             label: "docker compose config"
           ) do
        {:ok, _} -> decode_file(out)
        {:error, output} -> compose_config_failed(output, ctx)
      end

    File.rm(out)
    result
  end

  # Compose quotes whatever file it fails to parse, and a repo can point it
  # at any file the agent can read, so the output goes to the operation
  # log (which is redacted) and never into the error.
  defp compose_config_failed(output, ctx) do
    Enum.each(String.split(last_lines(output), "\n"), &ctx.log.("info", &1 <> "\n"))

    if output =~ "unknown flag",
      do: {:error, "docker compose config failed: this box's Docker Compose is too old"},
      else: {:error, "docker compose config failed; see the log for compose's output"}
  end

  defp decode_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- JSON.decode(content) do
      {:ok, decoded}
    else
      _ -> {:error, "couldn't read docker compose config output"}
    end
  end

  defp write_overlay(path, paths, spec, services, service, base, ctx) do
    yaml =
      Overlay.compose(%{
        env_id: spec.env_id,
        slug: spec.slug,
        services: services,
        networks: own_networks(base),
        devcontainer_service: service,
        secrets_dir: paths.secrets,
        tailscale: spec.tailscale,
        limits: spec.limits,
        feature_version: Config.feature_version(ctx.config)
      })

    SafeFS.write_atomic(path, yaml, 0o600)
  end

  # The Docker names of the networks compose will use.
  defp network_names_in(merged) do
    for {_key, %{"name" => name}} <- Map.get(merged, "networks") || %{},
        is_binary(name),
        do: name
  end

  # The networks compose creates for the project, with their Docker
  # names. An external one already exists, so its bridge isn't compose's
  # to name (the policy refuses it).
  defp own_networks(base) do
    for {key, spec} <- Enum.sort(Map.get(base, "networks") || %{}),
        is_map(spec),
        spec["external"] not in [true, "true"],
        do: {key, spec["name"] || "#{base["name"]}_#{key}"}
  end

  defp write_override(path, config, compose_files, overlay_path) do
    override =
      Overlay.override_config(config, compose_files: compose_files, overlay_path: overlay_path)

    SafeFS.write_atomic(path, JSON.encode!(override), 0o600)
  end

  # Before compose reads anything: compose reads env files, label files
  # and the files it includes or extends while it parses, folds some of
  # them in where the path no longer shows, and quotes any it can't parse
  # in its error. See ForemanAgent.Env.ComposeScan.
  defp scan_compose(paths, compose_files, spec, config) do
    with {:ok, facts} <- ComposeScan.scan(paths.clone, compose_files) do
      case Policy.check_sources(facts, policy_ctx(paths, spec, config)) do
        {:ok, warnings} -> {:ok, warnings}
        {:error, refused} -> {:error, refusal(refused)}
      end
    end
  end

  # A service's runtime is checked against the runtimes Docker has.
  defp check_policy(merged, devcontainer, paths, spec, config, docker) do
    ctx = Map.put(policy_ctx(paths, spec, config), :runtimes, docker["Runtimes"] || %{})

    case Policy.check(merged, devcontainer, ctx) do
      {:ok, warnings} -> {:ok, warnings}
      {:error, refused} -> {:error, refusal(refused)}
    end
  end

  # The box's Docker can hand out GPUs without a reservation; see
  # Policy.check_docker/2. Without /info there's no telling, so it's
  # refused.
  defp docker_info(ctx) do
    case ctx.docker.info() do
      {:ok, info} when is_map(info) -> {:ok, info}
      other -> {:error, "couldn't check Docker's default runtime on this box: #{inspect(other)}"}
    end
  end

  defp check_docker(info, paths, spec, config) do
    case Policy.check_docker(info, policy_ctx(paths, spec, config)) do
      {:ok, warnings} -> {:ok, warnings}
      {:error, refused} -> {:error, refusal(refused)}
    end
  end

  defp policy_ctx(paths, spec, config) do
    %{
      project: spec.slug,
      workspace_root: paths.workspace,
      secrets_dir: paths.secrets,
      protected: ForemanAgent.Config.protected_paths(config),
      rules: config.policy_rules,
      user_features: spec |> Map.get(:features, %{}) |> Map.keys()
    }
  end

  defp refusal(refused),
    do: "refused by this box's policy:\n" <> Enum.map_join(refused, "\n", &("- " <> &1))

  # The CLI resolves local features against the repo's devcontainer
  # folder, so the feature is copied in there (and excluded from git).
  defp install_feature(clone, config_dir, ctx) do
    case SafeFS.ensure_dir(clone, Path.join(config_dir, ".foreman")) do
      {:ok, dir} ->
        dest = Path.join(dir, "feature")
        File.rm_rf!(dest)
        File.cp_r!(ctx.config.feature_dir, dest)
        # dir is where it really is, if the config folder is a symlink.
        exclude_from_git(clone, "/" <> Path.relative_to(dir, Path.expand(clone)) <> "/")

      {:error, reason} ->
        {:error, "couldn't install the Foreman feature: #{inspect(reason)}"}
    end
  end

  defp exclude_from_git(clone, pattern) do
    case SafeFS.append_line(clone, ".git/info/exclude", pattern) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("couldn't update .git/info/exclude: #{inspect(reason)}")
    end

    :ok
  end

  # -- feature version -----------------------------------------------------

  # The overlay labels the devcontainer with the feature version when the
  # container is created, which is when the CLI builds its image. The CLI
  # starts a container that exists without recreating it, so the label is
  # the feature that's in it.
  defp put_feature_version(result, ctx, env_id, service) do
    case built_feature(ctx, env_id, service) do
      {:ok, version} -> Map.put(result, "feature_version", version)
      _ -> Map.put(result, "feature_version", nil)
    end
  end

  # With no container the CLI builds one anyway, so only one it would
  # reuse is rebuilt: one without a label was made before the agent set it.
  defp feature_rebuild(ctx, env_id, prepared, opts) do
    with true <- Keyword.get(opts, :feature_rebuild, true),
         {:ok, built} <- built_feature(ctx, env_id, prepared.devcontainer_service),
         true <- below_floor?(built) and not below_floor?(Config.feature_version(ctx.config)) do
      ctx.log.(
        "info",
        "This environment was built with an older Foreman feature (#{built || "unrecorded"}); rebuilding it\n"
      )

      {:ok, true}
    else
      {:error, reason} ->
        {:error, "couldn't check the environment's containers: #{inspect(reason)}"}

      _ ->
        {:ok, false}
    end
  end

  # The oldest among the service's containers: a replica scaled up later,
  # without a build, has a newer label than its image. If the replicas
  # built with the image are removed by hand, the rest overstate it, and
  # a start can skip the floor's rebuild.
  defp built_feature(ctx, env_id, service) do
    with {:ok, containers} <- ctx.docker.list_containers(["foreman.env_id=#{env_id}"]) do
      case Enum.filter(containers, &(&1["Labels"]["com.docker.compose.service"] == service)) do
        [] -> :none
        found -> {:ok, found |> Enum.map(&label_version/1) |> oldest()}
      end
    end
  end

  defp label_version(container) do
    version = container["Labels"]["foreman.feature_version"]
    if is_binary(version) and match?({:ok, _}, Version.parse(version)), do: version
  end

  defp oldest(versions), do: if(nil in versions, do: nil, else: Enum.min(versions, Version))

  defp below_floor?(nil), do: true
  defp below_floor?(version), do: Version.compare(version, @feature_floor) == :lt

  # -- devcontainer up -----------------------------------------------------

  defp devcontainer_up(paths, spec, prepared, p, ctx, opts) do
    with_docker_config(paths, Map.get(p, :registry_auth), fn docker_config ->
      # COMPOSE_REMOVE_ORPHANS: a service the repo dropped from its compose
      # files would otherwise leave its container behind, and the
      # environment would read as partial. Only here, where the CLI passes
      # every compose file; a compose run with fewer would count the
      # services it doesn't see as orphans.
      env =
        ctx
        |> compose_env(spec.slug, Map.get(p, :compose_env, %{}))
        |> Map.put("COMPOSE_REMOVE_ORPHANS", "true")
        |> then(&if(docker_config, do: Map.put(&1, "DOCKER_CONFIG", docker_config), else: &1))

      config_args = [
        "--workspace-folder",
        paths.clone,
        "--config",
        Path.join(paths.clone, spec.config_path),
        "--override-config",
        prepared.override_path,
        "--additional-features",
        JSON.encode!(
          Map.put(prepared.features, @feature_ref, Overlay.feature_options(spec.tailscale))
        ),
        "--log-format",
        "json",
        "--oci-auth-hardening"
      ]

      with {:ok, warnings} <- check_resolved(config_args, env, paths, spec, ctx),
           :ok <- move_to_foreman_bridges(ctx, spec.slug, prepared.networks) do
        warnings = Enum.uniq(prepared.warnings ++ warnings)
        result = up(paths, spec, %{prepared | warnings: warnings}, config_args, env, ctx, opts)

        # Even after a failed up: a lifecycle command can fail it with the
        # containers already running.
        with {:ok, result} <- checked(result, check_foreman_bridges(ctx, spec.slug)) do
          {:ok, put_feature_version(result, ctx, spec.env_id, prepared.devcontainer_service)}
        end
      end
    end)
  end

  defp checked(result, :ok), do: result
  defp checked({:error, message}, {:error, check}), do: {:error, "#{message}\n\n#{check}"}
  defp checked(_result, error), do: error

  # The box's firewall knows environment traffic by its fm- bridge (see
  # Overlay), and nothing moves an existing network onto one by itself:
  # the CLI leaves a running environment alone, and compose reuses a
  # network it didn't label with a config hash, or didn't create. A
  # network compose labelled is recreated by its next up once the project
  # is stopped, containers kept. Anything else would mean taking the
  # containers down, and what they hold (an anonymous volume's data, say)
  # with them, so it's refused before anything starts.
  defp move_to_foreman_bridges(ctx, slug, names) do
    with {:ok, stale} <- stale_networks(ctx, names) do
      {recreated, kept} =
        Enum.split_with(stale, &(compose_label(&1) == slug and config_hash?(&1)))

      cond do
        kept != [] ->
          {:error,
           "the Docker network #{network_names(kept)} isn't on a Foreman bridge, and compose would keep using it as it is, out of the box firewall's sight; destroy the environment and create it again, or remove the network on the box"}

        recreated != [] ->
          ctx.log.("info", "Moving #{network_names(recreated)} onto Foreman bridges\n")
          with {:ok, _} <- compose(ctx, slug, ["stop"]), do: :ok

        true ->
          :ok
      end
    end
  end

  # The existing networks the project's compose config names, matched by
  # exact name (Docker's name filter matches substrings).
  defp stale_networks(_ctx, []), do: {:ok, []}

  defp stale_networks(ctx, names) do
    with {:ok, networks} <- list_networks(ctx, %{"name" => names}) do
      {:ok, Enum.filter(networks, &(&1["Name"] in names and not foreman_bridge?(&1)))}
    end
  end

  # What the containers really got, whatever compose was asked for.
  defp check_foreman_bridges(ctx, slug) do
    with {:ok, containers} <- list_project_containers(ctx, slug),
         {:ok, stale} <- stale_attachments(ctx, containers) do
      case stale do
        [] ->
          :ok

        _ ->
          stop_unsafe(
            ctx,
            slug,
            "#{Enum.join(stale, ", ")} isn't on a Foreman bridge, so the box's firewall can't keep it off the tailnet"
          )
      end
    else
      {:error, message} -> stop_unsafe(ctx, slug, message)
    end
  end

  defp stop_unsafe(ctx, slug, why) do
    case compose(ctx, slug, ["stop"]) do
      {:ok, _} -> {:error, "#{why}; the environment is stopped"}
      {:error, stop} -> {:error, "#{why}, and Foreman couldn't stop the environment: #{stop}"}
    end
  end

  defp stale_attachments(ctx, containers) do
    attachments =
      for c <- containers,
          {_, %{"NetworkID" => id}} <- get_in(c, ["NetworkSettings", "Networks"]) || %{},
          do: {container_name(c), id}

    case Enum.uniq(for {_, id} <- attachments, do: id) do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, networks} <- list_networks(ctx, %{"id" => ids}) do
          ok =
            for n <- networks,
                n["Driver"] == "null" or foreman_bridge?(n),
                into: MapSet.new(),
                do: n["Id"]

          {:ok, for({name, id} <- attachments, id not in ok, uniq: true, do: name)}
        end
    end
  end

  defp container_name(%{"Names" => [name | _]}), do: String.trim_leading(name, "/")
  defp container_name(c), do: c["Id"]

  defp list_project_containers(ctx, slug) do
    case ctx.docker.list_containers(["com.docker.compose.project=#{slug}"]) do
      {:ok, containers} ->
        {:ok, containers}

      {:error, reason} ->
        {:error, "couldn't list this environment's containers: #{inspect(reason)}"}
    end
  end

  defp list_networks(ctx, filters) do
    case ctx.docker.list_networks(filters) do
      {:ok, networks} -> {:ok, networks}
      {:error, reason} -> {:error, "couldn't list Docker networks: #{inspect(reason)}"}
    end
  end

  # The option alone proves nothing: other drivers keep it and ignore it.
  defp foreman_bridge?(%{"Driver" => "bridge", "Options" => options}) do
    case options do
      %{"com.docker.network.bridge.name" => name} when is_binary(name) ->
        String.starts_with?(name, Overlay.bridge_prefix())

      _ ->
        false
    end
  end

  defp foreman_bridge?(_network), do: false

  defp compose_label(network), do: (network["Labels"] || %{})["com.docker.compose.project"]

  defp config_hash?(network),
    do: (network["Labels"] || %{})["com.docker.compose.config-hash"] not in [nil, ""]

  defp network_names(networks), do: Enum.map_join(networks, ", ", & &1["Name"])

  # Features can ask for privileges in their own metadata, which only the
  # CLI resolves. Ask it what the devcontainer will get before running it.
  #
  # Given no id label, read-configuration looks for a container by the
  # CLI's default labels, which a repo can give a service, and then takes
  # the merged config from that container instead of resolving features.
  # A label no container has makes it resolve them from the config every
  # time, and the result has to show it did.
  defp check_resolved(config_args, env, paths, spec, ctx) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    args =
      [
        "read-configuration",
        "--include-merged-configuration",
        "--id-label",
        "foreman.check=#{nonce}"
      ] ++
        config_args

    with {:ok, %{status: status, output: output}} <-
           run_tool(
             ctx,
             ctx.config.devcontainer,
             args,
             [
               env: env,
               keep: 1_048_576,
               timeout: @command_timeout,
               label: "devcontainer read-configuration"
             ],
             fn _ -> nil end
           ) do
      resolved =
        output
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case JSON.decode(line) do
            {:ok, %{"mergedConfiguration" => _} = resolved} -> resolved
            _ -> nil
          end
        end)

      cond do
        status != 0 or is_nil(resolved) ->
          {:error, "devcontainer read-configuration failed: #{last_lines(output)}"}

        not resolved_feature?(resolved, @feature_ref) ->
          {:error,
           "couldn't check what the devcontainer's features ask for: " <>
             "the devcontainer CLI didn't resolve them"}

        true ->
          case Policy.check_resolved(resolved, policy_ctx(paths, spec, ctx.config)) do
            {:ok, warnings} ->
              Enum.each(warnings, &ctx.log.("info", "Warning: #{&1}\n"))
              {:ok, warnings}

            {:error, refused} ->
              {:error, refusal(refused)}
          end
      end
    end
  end

  defp resolved_feature?(resolved, ref) do
    sets = get_in(resolved, ["featuresConfiguration", "featureSets"])

    is_list(sets) and
      Enum.any?(sets, &(get_in(&1, ["sourceInformation", "userFeatureId"]) == ref))
  end

  defp up(paths, spec, prepared, config_args, env, ctx, opts) do
    args =
      ["up" | config_args] ++
        [
          "--id-label",
          "foreman.env_id=#{spec.env_id}",
          "--skip-post-attach",
          # hostRequirements.gpu (the repo's or an image's) would have the
          # CLI reserve GPUs after the policy has checked compose.
          "--gpu-availability",
          "none"
        ] ++
        lockfile_args(paths.clone, spec.config_path) ++
        dotfiles_args(Map.get(spec, :dotfiles)) ++
        if(opts[:rebuild], do: ["--remove-existing-container"], else: [])

    ctx.log.("info", "Starting the devcontainer\n")

    with {:ok, %{status: status, output: output}} <-
           run_tool(
             ctx,
             ctx.config.devcontainer,
             args,
             [env: env, keep: 262_144, timeout: @up_timeout, label: "devcontainer up"],
             &devcontainer_log/1
           ) do
      up_outcome(status, output, spec, prepared)
    end
  end

  defp up_outcome(status, output, spec, prepared) do
    case {status, find_outcome(output)} do
      {0, %{"outcome" => "success"} = outcome} ->
        {:ok,
         %{
           "container_id" => outcome["containerId"],
           "remote_user" => outcome["remoteUser"],
           "remote_workspace_folder" => outcome["remoteWorkspaceFolder"],
           "compose_project" => outcome["composeProjectName"] || spec.slug,
           "services" => prepared.services,
           "devcontainer_service" => prepared.devcontainer_service,
           "warnings" => prepared.warnings,
           "host_requirements" => prepared.config["hostRequirements"]
         }}

      {_, %{"message" => message} = outcome} ->
        {:error,
         "devcontainer up failed: #{gpu_hint(output, prepared)}#{message}#{describe(outcome)}"}

      {status, nil} ->
        {:error,
         "#{gpu_hint(output, prepared)}#{exited("devcontainer up", status)} without reporting a result. " <>
           output_below(last_lines(output, &devcontainer_log/1))}

      {_, _} ->
        {:error,
         "devcontainer up failed: #{gpu_hint(output, prepared)}#{last_lines(output, &devcontainer_log/1)}"}
    end
  end

  @signals %{
    1 => "SIGHUP",
    2 => "SIGINT",
    6 => "SIGABRT",
    9 => "SIGKILL",
    11 => "SIGSEGV",
    13 => "SIGPIPE",
    15 => "SIGTERM"
  }

  # MuonTrap reports a command killed by a signal as 128 + the signal.
  defp exited(label, status) do
    case @signals[status - 128] do
      nil -> "#{label} exited with status #{status}"
      signal -> "#{label} was killed by #{signal} (status #{status})"
    end
  end

  defp output_below(""), do: "It printed nothing."
  defp output_below(tail), do: "Its last output is below.\n" <> tail

  # Docker's error when no device driver it knows takes the request,
  # which for an NVIDIA GPU means the toolkit's hook isn't installed.
  defp gpu_hint(output, %{gpus: true}) do
    if output =~ "could not select device driver",
      do:
        "Docker has no driver for this environment's GPUs; the box needs the NVIDIA driver and " <>
          "the NVIDIA Container Toolkit (nvidia-container-toolkit). ",
      else: ""
  end

  defp gpu_hint(_output, _prepared), do: ""

  # The CLI writes devcontainer-lock.json next to the config. Keep that
  # behaviour for repos that commit one; otherwise it'd leave an untracked
  # file in every workspace.
  defp lockfile_args(clone, config_path) do
    lockfile = Path.join(Path.dirname(config_path), "devcontainer-lock.json")

    case SafeFS.resolve(clone, lockfile) do
      {:ok, _} -> []
      {:error, _} -> ["--no-lockfile"]
    end
  end

  defp describe(%{"description" => d}) when is_binary(d) and d != "", do: " (#{d})"
  defp describe(_), do: ""

  defp dotfiles_args(nil), do: []

  defp dotfiles_args(dotfiles) do
    ["--dotfiles-repository", dotfiles.repository] ++
      if(dotfiles[:install_command],
        do: ["--dotfiles-install-command", dotfiles.install_command],
        else: []
      ) ++
      if(dotfiles[:target_path], do: ["--dotfiles-target-path", dotfiles.target_path], else: [])
  end

  defp find_outcome(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(&outcome_in/1)
  end

  # The CLI writes its outcome to stdout as a line of its own, but stderr
  # comes through the same pipe, so a long log line can be split around
  # it. The outcome still ends the line it lands in.
  defp outcome_in(line) do
    with [_ | _] = matches <- :binary.matches(line, ~s({"outcome":)),
         {at, _} = List.last(matches),
         {:ok, %{"outcome" => _} = outcome} <-
           JSON.decode(binary_part(line, at, byte_size(line) - at)) do
      outcome
    else
      _ -> outcome_line(line)
    end
  end

  defp outcome_line("{" <> _ = line) do
    case JSON.decode(line) do
      {:ok, %{"outcome" => _} = outcome} -> outcome
      _ -> nil
    end
  end

  defp outcome_line(_line), do: nil

  # The CLI's --log-format json lines carry a "text" field; anything else
  # (build output from docker) passes through as is. Debug-level entries
  # are dropped, and so are the CLI's dumps of the merged compose config,
  # which carry interpolated secret values.
  defp devcontainer_log(line) do
    case JSON.decode(line) do
      {:ok, %{"outcome" => _}} ->
        nil

      {:ok, %{"type" => "text", "level" => level, "text" => text}} when level >= 3 ->
        unless compose_dump?(text), do: text

      {:ok, %{"type" => "raw", "text" => text}} ->
        text

      {:ok, %{}} ->
        nil

      _ ->
        line
    end
  end

  defp compose_dump?(text) do
    String.starts_with?(text, ["name: ", "services:", "Docker Compose override file"]) and
      String.contains?(text, "services:")
  end

  # Registry credentials go in a throwaway DOCKER_CONFIG for the one
  # command that needs them, never on a command line.
  defp with_docker_config(_paths, nil, fun), do: fun.(nil)
  defp with_docker_config(_paths, [], fun), do: fun.(nil)

  defp with_docker_config(paths, auths, fun) do
    dir =
      Path.join(
        paths.meta,
        "docker-" <> (9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    config = %{
      "auths" =>
        Map.new(auths, fn a ->
          {a.host, %{"auth" => Base.encode64("#{a.username}:#{a.token}")}}
        end)
    }

    :ok = SafeFS.write_atomic(Path.join(dir, "config.json"), JSON.encode!(config), 0o600)
    link_cli_plugins(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  defp link_cli_plugins(dir) do
    home = System.get_env("DOCKER_CONFIG") || Path.join(System.user_home!(), ".docker")
    plugins = Path.join(home, "cli-plugins")
    if File.dir?(plugins), do: File.ln_s(plugins, Path.join(dir, "cli-plugins"))
  end

  defp save_spec(paths, spec, prepared, result) do
    saved =
      spec
      |> Map.put(:devcontainer_service, prepared.devcontainer_service)
      |> Map.put(:remote_user, result["remote_user"])
      |> Map.put(:remote_workspace_folder, result["remote_workspace_folder"])

    SafeFS.write_atomic(spec_path(paths), :erlang.term_to_binary(saved), 0o600)
  end

  defp spec_path(paths), do: Path.join(paths.meta, "spec.term")

  defp load_spec(config, env_id) do
    case File.read(spec_path(paths(config, env_id))) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary, [:safe])}
      {:error, _} -> {:error, "this box has no record of the environment; rebuild it"}
    end
  end

  # -- stop / restart ------------------------------------------------------

  defp stop(p, ctx) do
    case cmd(ctx, ctx.config.docker, ["compose", "-p", p.slug, "stop"],
           env: %{},
           label: "docker compose stop"
         ) do
      {:ok, _} -> {:ok, %{}}
      {:error, output} -> {:error, "docker compose stop failed: #{last_lines(output)}"}
    end
  end

  defp restart(%{mode: "all"} = p, ctx) do
    with {:ok, _} <- stop(p, ctx),
         {:ok, result} <- start(p, ctx) do
      {:ok, %{"restarted" => "all", "feature_version" => result["feature_version"]}}
    end
  end

  defp restart(%{mode: "affected"} = p, ctx) do
    with {:ok, spec} <- load_spec(ctx.config, p.env_id) do
      paths = paths(ctx.config, p.env_id, spec.repo)
      env = compose_env(ctx, spec.slug, p.compose_env)

      with {:ok, prepared} <- prepare(paths, spec, p.compose_env, ctx),
           files = prepared.compose_files ++ [prepared.overlay_path],
           {:ok, raw} <-
             compose_config(ctx, spec.slug, files, env, paths.meta, extra: ["--no-interpolate"]) do
        affected = Affected.services(raw, p.changed)
        restart_affected(affected, paths, spec, prepared, p, ctx, files, env)
      end
    end
  end

  defp restart_affected(affected, paths, spec, prepared, p, ctx, files, env) do
    service = prepared.devcontainer_service
    sidecars = affected -- [service]

    with {:ok, outdated} <- feature_rebuild(ctx, p.env_id, prepared, []),
         rebuild = service in affected or outdated,
         :ok <- recreate_checked(ctx, spec.slug, files, env, sidecars, prepared),
         {:ok, _} <- compose(ctx, spec.slug, ["stop", service]),
         # Recreating the devcontainer itself means the CLI has to do it,
         # since it owns the image and labels.
         {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, rebuild: rebuild) do
      {:ok,
       %{"restarted" => sidecars ++ [service], "feature_version" => result["feature_version"]}}
    end
  end

  # Compose recreates sidecars itself, so they get the same checks as
  # the CLI's up (see devcontainer_up).
  defp recreate_checked(_ctx, _slug, _files, _env, [], _prepared), do: :ok

  defp recreate_checked(ctx, slug, files, env, services, prepared) do
    with :ok <- move_to_foreman_bridges(ctx, slug, prepared.networks) do
      result = recreate(ctx, slug, files, env, services, prepared)
      checked(result, check_foreman_bridges(ctx, slug))
    end
  end

  defp recreate(ctx, slug, files, env, services, prepared) do
    args =
      ["compose", "-p", slug] ++
        Enum.flat_map(files, &["-f", &1]) ++
        ["up", "-d", "--no-deps", "--force-recreate"] ++ services

    case cmd(ctx, ctx.config.docker, args, env: env, label: "docker compose up") do
      {:ok, _} ->
        :ok

      {:error, output} ->
        {:error,
         "recreating #{Enum.join(services, ", ")} failed: #{gpu_hint(output, prepared)}#{last_lines(output)}"}
    end
  end

  defp compose(ctx, slug, args) do
    case cmd(ctx, ctx.config.docker, ["compose", "-p", slug | args],
           env: %{},
           label: "docker compose #{hd(args)}"
         ) do
      {:ok, out} -> {:ok, out}
      {:error, output} -> {:error, "docker compose #{hd(args)} failed: #{last_lines(output)}"}
    end
  end

  # -- destroy -------------------------------------------------------------

  defp destroy(p, ctx) do
    paths = paths(ctx.config, p.env_id)

    with {:ok, _} <- compose(ctx, p.slug, ["down", "--volumes", "--remove-orphans"]),
         :ok <- remove_tree(paths.env_dir, ctx) do
      File.rm_rf(paths.secrets)
      {:ok, %{}}
    end
  end

  defp remove_tree(dir, ctx) do
    with :ok <- remove_in(ctx, dir, ["workspace", "meta"]) do
      case File.rm_rf(dir) do
        {:ok, _} -> :ok
        {:error, _, _} -> {:error, "couldn't remove #{dir}"}
      end
    end
  end

  # Removes `names` under `parent`. Files a container created as root
  # can't be removed by the agent's user; a throwaway container removes
  # what's left.
  defp remove_in(ctx, parent, names) do
    paths = Enum.map(List.wrap(names), &Path.join(parent, &1))

    if Enum.all?(paths, &match?({:ok, _}, File.rm_rf(&1))) do
      :ok
    else
      args =
        ["run", "--rm", "--network", "none", "-v", "#{parent}:/target", ctx.config.cleanup_image] ++
          ["rm", "-rf" | Enum.map(List.wrap(names), &("/target/" <> &1))]

      with {:ok, _} <- cmd(ctx, ctx.config.docker, args, env: %{}, label: "cleanup container"),
           true <- Enum.all?(paths, &match?({:ok, _}, File.rm_rf(&1))) do
        :ok
      else
        _ -> {:error, "couldn't remove #{Enum.join(paths, ", ")}"}
      end
    end
  end

  # -- logs / git status ---------------------------------------------------

  defp logs(p, ctx) do
    args = [
      "compose",
      "-p",
      p.slug,
      "logs",
      "--no-color",
      "--timestamps",
      "--tail",
      Integer.to_string(p.tail)
    ]

    args = if p[:service], do: args ++ [p.service], else: args

    case ctx.runner.run(ctx.config.docker, args,
           env: base_env(ctx),
           on_output: &ctx.log.("stdout", &1),
           timeout: @logs_timeout
         ) do
      {:ok, %{status: 0}} -> {:ok, %{}}
      {:ok, %{status: :timeout}} -> {:error, timed_out("docker compose logs", @logs_timeout)}
      {:ok, %{output: output}} -> {:error, "docker compose logs failed: #{last_lines(output)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp git_status(p, ctx) do
    with {:ok, spec} <- load_spec(ctx.config, p.env_id),
         {:ok, container} <- devcontainer_container(ctx, p.env_id, spec.devcontainer_service) do
      git = &container_git(ctx, spec, container, &1, &2)

      with {:ok, status} <- git.(["status", "--porcelain=v1", "--branch"], "git status"),
           {:ok, unpushed} <-
             git.(["log", "--branches", "--not", "--remotes", "--oneline"], "git log"),
           {:ok, summary} <- git_summary(String.split(status, "\n", trim: true), unpushed) do
        {:ok,
         Map.merge(summary, %{
           "head" => git_object(git, ["rev-parse", "HEAD"], "git rev-parse"),
           "base" => git_object(git, ["merge-base", "HEAD", "@{upstream}"], "git merge-base")
         })}
      else
        {:error, output} -> {:error, "git status failed: #{last_lines(output)}"}
      end
    end
  end

  # git inside the devcontainer, as the remote user. The workspace's owner
  # inside the container depends on the host (Docker Desktop maps it to
  # root), so safe.directory is opened up.
  defp container_git(ctx, spec, container, args, label, opts \\ []) do
    exec =
      [
        "exec",
        "-u",
        spec.remote_user,
        "-w",
        spec.remote_workspace_folder,
        container,
        "git",
        "-c",
        "safe.directory=*",
        "-c",
        "core.fsmonitor=false"
      ] ++ args

    cmd(ctx, ctx.config.docker, exec,
      env: %{},
      quiet: Keyword.get(opts, :quiet, true),
      label: label
    )
  end

  # For comparing with the branch on GitHub. A repo with no commits has no
  # HEAD, and a branch with no upstream no merge base.
  defp git_object(git, args, label) do
    case git.(args, label) do
      {:ok, out} -> sha(out)
      {:error, _} -> nil
    end
  end

  # The container's git answers for itself, so only an object name is taken.
  defp sha(output) do
    trimmed = String.trim(output)
    if trimmed =~ ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, do: trimmed
  end

  # `--branch` always prints the "## " line first; no output at all means
  # the container went away under the exec.
  defp git_summary(["## " <> _ = branch_line | files], unpushed) do
    {:ok,
     %{
       "branch" => branch_name(branch_line),
       "changed_files" => length(files),
       "unpushed_commits" => unpushed |> String.split("\n", trim: true) |> length(),
       "ahead" => ahead(branch_line),
       "clean" => files == [] and String.trim(unpushed) == ""
     }}
  end

  defp git_summary(_lines, _unpushed),
    do: {:error, "no output from the container; is it still running?"}

  defp branch_name("## " <> rest),
    do: rest |> String.split("...") |> hd() |> String.split(" ") |> hd()

  defp branch_name(_), do: nil

  # Commits on the branch that aren't on its upstream, as of the last fetch.
  defp ahead(branch_line) do
    case Regex.run(~r/\[ahead (\d+)/, branch_line) do
      [_, n] -> String.to_integer(n)
      nil -> 0
    end
  end

  defp devcontainer_container(ctx, env_id, service) do
    case ctx.docker.list_containers(["foreman.env_id=#{env_id}"]) do
      {:ok, containers} ->
        case Enum.find(
               containers,
               &(&1["Labels"]["com.docker.compose.service"] == service and
                   &1["State"] == "running")
             ) do
          %{"Id" => id} -> {:ok, id}
          nil -> {:error, "the environment isn't running; start it to check its git status"}
        end

      {:error, reason} ->
        {:error, "couldn't list containers: #{inspect(reason)}"}
    end
  end

  # -- helpers -------------------------------------------------------------

  defp base_env(ctx) do
    %{"DOCKER_HOST" => "unix://" <> ctx.config.docker_socket}
  end

  defp compose_env(ctx, slug, compose_env) do
    compose_env
    |> Map.merge(base_env(ctx))
    |> Map.put("COMPOSE_PROJECT_NAME", slug)
  end

  defp cmd(ctx, command, args, opts) do
    env = Map.merge(base_env(ctx), Keyword.get(opts, :env, %{}))
    mapper = if opts[:quiet], do: fn _ -> nil end, else: & &1
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    run_opts = [env: env, timeout: timeout, label: opts[:label]]

    case run_tool(ctx, command, args, run_opts, mapper) do
      {:ok, %{status: 0, output: output}} -> {:ok, output}
      {:ok, %{output: output}} -> {:error, output}
      {:error, message} -> {:error, message}
    end
  end

  # run_lines/5, with a tool that couldn't be run as an error message.
  defp run_tool(ctx, command, args, opts, mapper) do
    case run_lines(ctx, command, args, opts, mapper) do
      {:ok, %{status: :timeout}} ->
        {:error, timed_out(opts[:label] || Path.basename(command), opts[:timeout])}

      {:ok, result} ->
        {:ok, result}

      {:error, {:not_found, command}} ->
        {:error, "#{command} is not installed on this box"}

      {:error, reason} ->
        {:error, "couldn't run #{command}: #{inspect(reason)}"}
    end
  end

  # Runs a command, re-chunking its output into lines. Each line goes
  # through `mapper` (nil drops it) to the operation log.
  defp run_lines(ctx, command, args, opts, mapper) do
    key = {__MODULE__, :pending, make_ref()}
    spinner = {__MODULE__, :spinner, make_ref()}

    emit = fn lines ->
      {texts, last} = log_lines(lines, mapper, Process.get(spinner))
      Process.put(spinner, last)

      for text <- texts do
        ctx.log.("info", if(String.ends_with?(text, "\n"), do: text, else: text <> "\n"))
      end
    end

    on_output = fn chunk ->
      parts = String.split(Process.get(key, "") <> chunk, "\n")
      Process.put(key, List.last(parts))
      emit.(Enum.drop(parts, -1))
      :ok
    end

    try do
      ctx.runner.run(
        command,
        args,
        opts |> Keyword.delete(:label) |> Keyword.put(:on_output, on_output)
      )
    after
      case Process.delete(key) do
        rest when is_binary(rest) and rest != "" -> emit.([rest])
        _ -> :ok
      end

      Process.delete(spinner)
    end
  end

  # What the operation log shows for lines of a command's output: each
  # line through `mapper` (nil drops it), split into the lines it shows,
  # without colors or cursor movement. Lines that were only cursor
  # movement go, and so do spinner frames that redraw the one before
  # (clack and ora print one every 80 ms). `last` is the kept spinner
  # line's text, carried across chunks.
  defp log_lines(lines, mapper, last) do
    Enum.flat_map_reduce(lines, last, fn line, last ->
      case mapper.(line) do
        text when is_binary(text) -> text |> shown_lines() |> Enum.flat_map_reduce(last, &frame/2)
        _ -> {[], last}
      end
    end)
  end

  defp shown_lines(text) do
    lines = String.split(text, "\n")
    if String.ends_with?(text, "\n"), do: Enum.drop(lines, -1), else: lines
  end

  defp frame(line, last) do
    clean = line |> redrawn() |> strip_ansi()

    if blank?(clean) and String.contains?(line, ["\e", "\r"]) do
      {[], last}
    else
      case spinner_text(clean) do
        nil -> {[clean], nil}
        ^last -> {[], last}
        spinner -> {[clean], spinner}
      end
    end
  end

  # What's left on a line a CLI keeps redrawing (a progress count, a
  # spinner): the last text written after a return to the first column.
  # A return on its own erases nothing; an erase after it clears the line.
  @column_one ~r/\r|\e\[[01]?G/
  @erase ~r/\e\[[02]?[JK]/
  defp redrawn(line) do
    @column_one
    |> Regex.split(line)
    |> Enum.reverse()
    |> Enum.find("", &(not blank?(strip_ansi(&1)) or Regex.match?(@erase, &1)))
  end

  defp blank?(text), do: String.trim(text) == ""

  # A line that starts with a spinner frame, as the text after it with any
  # animated trailing dots left off.
  @spinner ~r/^\s*[\x{2800}-\x{28FF}◐◓◑◒◴◷◶◵◰◳◲◱◢◣◤◥◜◠◝◞◡◟▖▘▝▗✶✷✸✹✺]+\s+(.*?)[.…]*\s*$/u
  defp spinner_text(text) do
    case Regex.run(@spinner, text) do
      [_, rest] -> rest
      nil -> nil
    end
  end

  defp timed_out(label, timeout),
    do: "#{label} timed out after #{div(timeout || 0, 60_000)} minutes and was stopped"

  # Colors and cursor movement from CLIs, which a log view can't use.
  @ansi ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(\a|\e\\)|\r(?!\n)/
  defp strip_ansi(text), do: Regex.replace(@ansi, text, "")

  # The end of a command's output as the operation log shows it.
  defp last_lines(output, mapper \\ & &1) do
    {texts, _} = log_lines(String.split(output, "\n"), mapper, nil)

    texts
    |> Enum.reject(&blank?/1)
    |> Enum.take(-15)
    |> Enum.join("\n")
  end
end
