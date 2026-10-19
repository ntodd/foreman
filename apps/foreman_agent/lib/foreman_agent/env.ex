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

  @type ctx :: %{
          config: ForemanAgent.Config.t(),
          runner: module(),
          docker: module(),
          log: function()
        }

  @spec run(String.t(), map(), ctx()) :: {:ok, map()} | {:error, String.t()}
  def run("env.create", p, ctx), do: up(p, ctx, rebuild: false)
  def run("env.rebuild", p, ctx), do: up(p, ctx, rebuild: true)
  def run("env.start", p, ctx), do: start(p, ctx)
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
    spec = Map.drop(p, [:files, :compose_env, :registry_auth])

    with :ok <- check_clone_url(p.clone_url, ctx.config),
         :ok <- ensure_dirs(paths),
         {:ok, _} <- write_secrets(paths, p.files),
         :ok <- ensure_clone(paths, p, ctx),
         {:ok, prepared} <- prepare(paths, spec, p.compose_env, ctx),
         {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, opts) do
      save_spec(paths, spec, prepared, result)
      {:ok, result}
    end
  end

  defp start(p, ctx) do
    with {:ok, spec} <- load_spec(ctx.config, p.env_id) do
      paths = paths(ctx.config, p.env_id, spec.repo)
      ensure_secrets_dir(paths)

      with {:ok, prepared} <- prepare(paths, spec, p.compose_env, ctx),
           {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, rebuild: false) do
        save_spec(paths, spec, prepared, result)
        {:ok, result}
      end
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
         :ok <- write_overlay(overlay_path, paths, spec, services, service),
         {:ok, merged} <- files_config.(compose_files ++ [overlay_path], env),
         {:ok, policy_warnings} <- check_policy(merged, config, paths, spec, ctx.config),
         warnings = Enum.uniq(scan_warnings ++ policy_warnings),
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

  defp write_overlay(path, paths, spec, services, service) do
    yaml =
      Overlay.compose(%{
        env_id: spec.env_id,
        slug: spec.slug,
        services: services,
        devcontainer_service: service,
        secrets_dir: paths.secrets,
        tailscale: spec.tailscale,
        limits: spec.limits
      })

    SafeFS.write_atomic(path, yaml, 0o600)
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

  defp check_policy(merged, devcontainer, paths, spec, config) do
    case Policy.check(merged, devcontainer, policy_ctx(paths, spec, config)) do
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

  # -- devcontainer up -----------------------------------------------------

  defp devcontainer_up(paths, spec, prepared, p, ctx, opts) do
    with_docker_config(paths, Map.get(p, :registry_auth), fn docker_config ->
      env =
        ctx
        |> compose_env(spec.slug, Map.get(p, :compose_env, %{}))
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

      with {:ok, warnings} <- check_resolved(config_args, env, paths, spec, ctx) do
        warnings = Enum.uniq(prepared.warnings ++ warnings)
        up(paths, spec, %{prepared | warnings: warnings}, config_args, env, ctx, opts)
      end
    end)
  end

  # Features can ask for privileges in their own metadata, which only the
  # CLI resolves. Ask it what the devcontainer will get before running it.
  defp check_resolved(config_args, env, paths, spec, ctx) do
    args = ["read-configuration", "--include-merged-configuration" | config_args]

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

      if status != 0 or is_nil(resolved) do
        {:error, "devcontainer read-configuration failed: #{last_lines(output)}"}
      else
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

  defp up(paths, spec, prepared, config_args, env, ctx, opts) do
    args =
      ["up" | config_args] ++
        [
          "--id-label",
          "foreman.env_id=#{spec.env_id}",
          "--skip-post-attach"
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
        {:error, "devcontainer up failed: #{message}#{describe(outcome)}"}

      {status, nil} ->
        {:error,
         "#{exited("devcontainer up", status)} without reporting a result. " <>
           output_below(last_lines(output, &devcontainer_log/1))}

      {_, _} ->
        {:error, "devcontainer up failed: #{last_lines(output, &devcontainer_log/1)}"}
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
    |> Enum.find_value(fn line ->
      with "{" <> _ <- line,
           {:ok, %{"outcome" => _} = outcome} <- JSON.decode(line) do
        outcome
      else
        _ -> nil
      end
    end)
  end

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
         {:ok, _} <- start(p, ctx) do
      {:ok, %{"restarted" => "all"}}
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

    with :ok <- recreate(ctx, spec.slug, files, env, sidecars),
         {:ok, _} <- compose(ctx, spec.slug, ["stop", service]),
         # Recreating the devcontainer itself means the CLI has to do it,
         # since it owns the image and labels.
         {:ok, _} <- devcontainer_up(paths, spec, prepared, p, ctx, rebuild: service in affected) do
      {:ok, %{"restarted" => sidecars ++ [service]}}
    end
  end

  defp recreate(_ctx, _slug, _files, _env, []), do: :ok

  defp recreate(ctx, slug, files, env, services) do
    args =
      ["compose", "-p", slug] ++
        Enum.flat_map(files, &["-f", &1]) ++
        ["up", "-d", "--no-deps", "--force-recreate"] ++ services

    case cmd(ctx, ctx.config.docker, args, env: env, label: "docker compose up") do
      {:ok, _} ->
        :ok

      {:error, output} ->
        {:error, "recreating #{Enum.join(services, ", ")} failed: #{last_lines(output)}"}
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
      exec = [
        "exec",
        "-u",
        spec.remote_user,
        "-w",
        spec.remote_workspace_folder,
        container,
        # The workspace's owner inside the container depends on the host
        # (Docker Desktop maps it to root), and this only reads status.
        "git",
        "-c",
        "safe.directory=*",
        "-c",
        "core.fsmonitor=false"
      ]

      with {:ok, status} <-
             cmd(ctx, ctx.config.docker, exec ++ ["status", "--porcelain=v1", "--branch"],
               env: %{},
               quiet: true,
               label: "git status"
             ),
           {:ok, unpushed} <-
             cmd(
               ctx,
               ctx.config.docker,
               exec ++ ["log", "--branches", "--not", "--remotes", "--oneline"],
               env: %{},
               quiet: true,
               label: "git log"
             ) do
        git_summary(String.split(status, "\n", trim: true), unpushed)
      else
        {:error, output} -> {:error, "git status failed: #{last_lines(output)}"}
      end
    end
  end

  # `--branch` always prints the "## " line first; no output at all means
  # the container went away under the exec.
  defp git_summary(["## " <> _ = branch_line | files], unpushed) do
    {:ok,
     %{
       "branch" => branch_name(branch_line),
       "changed_files" => length(files),
       "unpushed_commits" => unpushed |> String.split("\n", trim: true) |> length(),
       "clean" => files == [] and String.trim(unpushed) == ""
     }}
  end

  defp git_summary(_lines, _unpushed),
    do: {:error, "git status failed: no output from the container; is it still running?"}

  defp branch_name("## " <> rest),
    do: rest |> String.split("...") |> hd() |> String.split(" ") |> hd()

  defp branch_name(_), do: nil

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
