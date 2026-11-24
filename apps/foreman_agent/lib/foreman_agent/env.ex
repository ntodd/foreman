defmodule ForemanAgent.Env do
  @moduledoc """
  Environment operations on this box.

  Layout, per environment:

      <envs_root>/<env_id>/workspace/<repo>   the clone (bind-mounted into the containers)
      <envs_root>/<env_id>/meta/              overlay, override config, saved spec (agent only)
      <secrets_root>/<env_id>/                secrets files (tmpfs, mounted at /run/foreman)

  This runs in the environment's own VM (the agent in guest mode, see
  `ForemanAgent.Guest`), which is the boundary: nothing the repo's compose
  files or devcontainer config ask for reaches the box. The workspace is
  writable from inside the environment, so everything the agent reads or
  writes there still goes through `ForemanAgent.SafeFS`.

  `run/3` takes a validated command payload and a context:

      %{config: %Config{}, runner: module, docker: module, log: fn stream, data -> ... end}
  """

  alias ForemanAgent.Config
  alias ForemanAgent.Env.{Affected, Overlay}
  alias ForemanAgent.Runner.Logged
  alias ForemanAgent.SafeFS
  alias ForemanAgent.VM.Prebuild
  alias ForemanProtocol.{Connect, Feature, Jsonc}

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
  # A hook's describe is a listing; its actions can restart a server. Each
  # is bounded inside the container (seconds), and docker exec a little
  # after: stopping docker exec doesn't stop what it started there.
  @describe_seconds 30
  @connect_seconds 240
  @hook_grace :timer.seconds(15)
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
  def run("env.connect", p, ctx), do: connect(p, ctx)

  # -- paths ---------------------------------------------------------------

  @doc false
  def paths(config, env_id, repo \\ nil) do
    env_dir = Path.join(config.envs_root, env_id)

    %{
      env_dir: env_dir,
      workspace: Path.join(env_dir, "workspace"),
      clone: repo && Path.join([env_dir, "workspace", repo |> String.split("/") |> List.last()]),
      meta: Path.join(env_dir, "meta"),
      recovery: Path.join([env_dir, "meta", "recovery"]),
      secrets: Path.join(config.secrets_root, env_id)
    }
  end

  # -- create / rebuild / start --------------------------------------------

  defp up(p, ctx, opts) do
    adopted? = adopt_prebuild(p, ctx)
    paths = paths(ctx.config, p.env_id, p.repo)
    spec = Map.drop(p, [:files, :compose_env, :registry_auth, :pull, :prebuild_id, :prebuild])
    # A clone this rebuild makes is already up to date.
    pull? = Map.get(p, :pull) == true and File.exists?(spec_path(paths))

    with :ok <- check_clone_url(p.clone_url, ctx.config),
         :ok <- ensure_dirs(paths),
         {:ok, _} <- write_secrets(paths, p.files),
         :ok <- if(adopted?, do: refresh_clone(paths, p, ctx), else: ensure_clone(paths, p, ctx)),
         :ok <- if(pull?, do: pull(p, ctx), else: :ok),
         {:ok, prepared} <- prepare(paths, spec, p.compose_env, ctx),
         {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, opts) do
      save_spec(paths, spec, prepared, result)
      if Map.get(p, :prebuild) == true, do: keep_base_images(paths, prepared, p, ctx)
      {:ok, result |> put_node_id(spec, ctx) |> put_connect_hooks(ctx)}
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
        result = if opts[:node_id], do: put_node_id(result, spec, ctx), else: result
        {:ok, put_connect_hooks(result, ctx)}
      end
    end
  end

  # A disk made from a prebuild (ForemanAgent.VM.Prebuild) has the
  # prebuild's clone, built images and saved spec under the prebuild's id.
  # The environment takes the clone over (refresh_clone/3 brings it up to
  # date) and bringing the devcontainer up makes the environment's own containers from the
  # images already there. The prebuild's spec goes, so nothing starts this
  # environment as the prebuild before its own is saved, and so do the
  # prebuild's containers and volumes: the environment's are its own,
  # under its own name. Never raises: a disk it can't take over is built
  # on as it is.
  defp adopt_prebuild(%{prebuild_id: id, env_id: env_id}, ctx) when is_binary(id) do
    from = paths(ctx.config, id)
    to = paths(ctx.config, env_id)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(from.env_dir),
         false <- File.exists?(to.env_dir),
         :ok <- File.rename(from.env_dir, to.env_dir) do
      ctx.log.("info", "Starting from the prebuild\n")
      _ = File.rm(spec_path(to))

      case compose(ctx, Prebuild.slug(id), ["down", "--volumes", "--remove-orphans"]) do
        {:ok, _} ->
          :ok

        {:error, message} ->
          ctx.log.("info", "Couldn't remove the prebuild's containers: #{message}\n")
      end

      true
    else
      _ -> false
    end
  end

  defp adopt_prebuild(_p, _ctx), do: false

  # A prebuild's clone, made this environment's: git's settings and hooks
  # back to what a fresh clone has (the prebuild's code could have changed
  # them, and git runs here as the agent), then the branch fetched with
  # this environment's own token and checked out, so it starts from the
  # branch as it is now. What the prebuild's hooks made in the tree stays.
  # Anything that doesn't work out, it's cloned afresh.
  defp refresh_clone(paths, p, ctx) do
    git_dir = Path.join(paths.clone, ".git")
    helper = write_credential_helper(paths)
    tracking = "refs/remotes/origin/" <> p.branch

    result =
      with {:ok, %File.Stat{type: :directory}} <- File.lstat(paths.clone),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(git_dir),
           :ok <- new_git_dir(paths.clone, git_dir, helper, p, ctx),
           {:ok, _} <-
             git_in(
               paths.clone,
               helper,
               p,
               ["fetch", "--no-tags", "origin", "+refs/heads/#{p.branch}:#{tracking}"],
               ctx
             ),
           {:ok, _} <-
             git_in(paths.clone, helper, p, ["checkout", "-f", "-B", p.branch, tracking], ctx) do
        :ok
      end

    case result do
      :ok ->
        :ok

      other ->
        ctx.log.(
          "info",
          "Couldn't bring the prebuild's clone up to date (#{inspect_short(other)}); cloning afresh\n"
        )

        with :ok <- remove_in(ctx, paths.workspace, Path.basename(paths.clone)),
             do: clone(paths, p, ctx)
    end
  end

  # A git directory of the environment's own, which the fetch then fills
  # from the remote: nothing the prebuild's code could have left in the
  # old one (replacement refs, alternate object stores, grafts, hooks,
  # config) is used, whatever it was.
  defp new_git_dir(clone, git_dir, helper, p, ctx) do
    with {:ok, _} <- File.rm_rf(git_dir),
         {:ok, _} <- git_in(clone, helper, p, ["init", "--quiet"], ctx),
         :ok <- File.mkdir_p(git_dir) do
      reset_git_dir(git_dir, p)
    end
  end

  defp reset_git_dir(git_dir, p) do
    config = """
    [core]
    \trepositoryformatversion = 0
    \tfilemode = true
    \tbare = false
    \tlogallrefupdates = true
    [remote "origin"]
    \turl = #{p.clone_url}
    \tfetch = +refs/heads/*:refs/remotes/origin/*
    [branch "#{p.branch}"]
    \tremote = origin
    \tmerge = refs/heads/#{p.branch}
    """

    hooks = Path.join(git_dir, "hooks")

    with :ok <- SafeFS.write_atomic(Path.join(git_dir, "config"), config, 0o644),
         {:ok, _} <- File.rm_rf(hooks) do
      File.mkdir(hooks)
    end
  end

  defp git_in(dir, helper, p, args, ctx) do
    opts =
      ["-c", "credential.helper=", "-c", "credential.helper=" <> helper] ++
        ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] ++
        ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"] ++
        http_protocol(p.clone_url)

    case cmd(ctx, ctx.config.git, opts ++ ["-C", dir | args], env: %{}, label: "git #{hd(args)}") do
      {:ok, out} -> {:ok, out}
      {:error, output} -> {:error, "git #{hd(args)} failed: #{last_lines(output)}"}
    end
  end

  defp inspect_short({:error, message}) when is_binary(message), do: message
  defp inspect_short(other), do: inspect(other)

  # BuildKit keeps a build's base images in its cache without tagging
  # them, so an environment's own build from a prebuild would ask the
  # registry about each again. Pulled by tag, they're in the image store
  # and the build takes them as they are. Best effort: a prebuild without
  # them still works.
  defp keep_base_images(paths, prepared, p, ctx) do
    case base_images(prepared.builds, paths.clone) do
      [] ->
        :ok

      refs ->
        ctx.log.("info", "Keeping the base images: #{Enum.join(refs, ", ")}\n")

        with_docker_config(paths, Map.get(p, :registry_auth), fn docker_config ->
          env = if docker_config, do: %{"DOCKER_CONFIG" => docker_config}, else: %{}
          Enum.each(refs, &pull_image(&1, env, ctx))
        end)
    end
  end

  defp pull_image(ref, env, ctx) do
    case cmd(ctx, ctx.config.docker, ["pull", "--quiet", ref], env: env, label: "docker pull") do
      {:ok, _} -> :ok
      {:error, output} -> ctx.log.("info", "Couldn't pull #{ref}: #{last_lines(output)}\n")
    end
  end

  # What compose builds from: a Dockerfile, or one inline.
  defp builds(compose) do
    for {_service, %{"build" => %{} = build}} <- Map.get(compose, "services", %{}),
        source = build_source(build),
        uniq: true,
        do: source
  end

  defp build_source(%{"dockerfile_inline" => inline}) when is_binary(inline),
    do: {:inline, inline}

  defp build_source(%{"context" => context} = build) when is_binary(context),
    do: {:file, Path.expand(Map.get(build, "dockerfile", "Dockerfile"), context)}

  defp build_source(_build), do: nil

  # Inside the clone and no bigger than a Dockerfile, read without
  # following a symlink out of it: the repo names the path.
  defp read_dockerfile(clone, path) do
    rel = Path.relative_to(path, clone)

    with :relative <- Path.type(rel),
         {:ok, content} <- SafeFS.read(clone, rel, max_bytes: 1_000_000) do
      [content]
    else
      _ -> []
    end
  end

  # FROM as Dockerfiles write it: a lowercase "from" is more likely a line
  # of Python in a heredoc than an instruction.
  @from ~r/^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+(?:AS|as)\s+(\S+))?/m

  # The images a Dockerfile's stages start from, less earlier stages,
  # scratch, and any named by a build argument.
  defp base_images(builds, clone) do
    builds
    |> Enum.flat_map(fn
      {:inline, content} -> [content]
      {:file, path} -> read_dockerfile(clone, path)
    end)
    |> Enum.flat_map(fn content ->
      froms = Regex.scan(@from, content)
      stages = for [_, _, stage] <- froms, do: String.downcase(stage)

      for [_, ref | _] <- froms,
          ref != "scratch",
          not String.contains?(ref, "$"),
          String.downcase(ref) not in stages,
          do: ref
    end)
    |> Enum.uniq()
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

  @doc false
  def check_clone_url(url, config) do
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
      with :ok <- preserve_failed_attempt(paths, p, ctx), do: clone(paths, p, ctx)
    end
  end

  # Move the whole checkout on the same disk, including untracked files
  # and local branches. Never run git in the old checkout as the agent.
  defp preserve_failed_attempt(paths, p, ctx) do
    case File.lstat(paths.clone) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        with {:ok, _} <- compose(ctx, p.slug, ["down", "--remove-orphans"]) do
          save_previous_workspace(paths, ctx)
        end

      {:error, reason} ->
        {:error, "couldn't inspect the previous workspace: #{:file.format_error(reason)}"}
    end
  end

  defp save_previous_workspace(paths, ctx) do
    attempt = "attempt-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- File.mkdir_p(paths.recovery),
         true <- recovery_directory?(paths),
         :ok <- File.rename(paths.clone, Path.join(paths.recovery, attempt)) do
      ctx.log.(
        "info",
        "Saved previous workspace at #{Overlay.recovery_mount()}/#{attempt} in the devcontainer\n"
      )

      :ok
    else
      false ->
        {:error, "couldn't save the previous workspace: invalid recovery directory"}

      {:error, reason} ->
        {:error, "couldn't save the previous workspace: #{:file.format_error(reason)}"}
    end
  end

  defp recovery_directory?(paths),
    do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(paths.recovery))

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

  # Every profile: bringing the devcontainer up starts the services runServices names, and
  # compose starts a profiled service it's asked for by name, so the
  # overlay covers them all.
  @check_args [profiles: :all]

  defp prepare(paths, spec, compose_env, ctx) do
    config_dir = config_dir(spec.config_path)
    files_config = &compose_config(ctx, spec.slug, &1, &2, paths.meta, @check_args)

    with {:ok, config, key_order} <- read_devcontainer(paths.clone, spec.config_path),
         {:ok, features} <- user_features(spec, config, ctx),
         {:ok, rel_files, service} <- compose_spec(config),
         {:ok, compose_files} <- resolve_compose_files(paths.clone, config_dir, rel_files),
         env = compose_env(ctx, spec.slug, compose_env),
         {:ok, base} <- files_config.(compose_files, env),
         services = base |> Map.get("services", %{}) |> Map.keys() |> Enum.sort(),
         :ok <- check_service(service, services),
         :ok <- check_run_services(config["runServices"], services),
         overlay_path = Path.join(paths.meta, "overlay.yml"),
         :ok <- write_overlay(overlay_path, paths, spec, services, service, ctx),
         :ok <- install_feature(paths.clone, config_dir, ctx) do
      {:ok,
       %{
         config: config,
         compose_files: compose_files,
         builds: builds(base),
         overlay_path: overlay_path,
         override:
           Overlay.override_config(config,
             compose_files: compose_files,
             overlay_path: overlay_path
           ),
         key_order: key_order,
         services: services,
         devcontainer_service: service,
         features: features,
         warnings: []
       }}
    end
  end

  # The features a user adds to their own environments, less any the repo
  # already declares at whatever version: the repo's copy is the one that
  # installs. None can take the Foreman feature's id. Refs are lowercased
  # when they're resolved
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
          {:ok, config} ->
            {:ok, config, %{"containerEnv" => Jsonc.key_order(content, ["containerEnv"])}}

          {:error, message} ->
            {:error, "#{rel}: #{message}"}
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

  defp write_overlay(path, paths, spec, services, service, ctx) do
    yaml =
      Overlay.compose(%{
        env_id: spec.env_id,
        slug: spec.slug,
        services: services,
        devcontainer_service: service,
        secrets_dir: paths.secrets,
        recovery_dir: if(recovery_directory?(paths), do: paths.recovery),
        tailscale: spec.tailscale,
        feature_version: Config.feature_version(ctx.config)
      })

    SafeFS.write_atomic(path, yaml, 0o600)
  end

  # Local features are resolved against the repo's devcontainer
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
  # container is created, which is when its image is built. Bringing it up
  # starts a container that exists without recreating it, so the label is
  # the feature that's in it.
  defp put_feature_version(result, ctx, env_id, service) do
    case built_feature(ctx, env_id, service) do
      {:ok, version} -> Map.put(result, "feature_version", version)
      _ -> Map.put(result, "feature_version", nil)
    end
  end

  # With no container one is built anyway, so only one that would be
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
      # environment would read as partial. Only here, where every compose
      # file is passed; a compose run with fewer would count the services
      # it doesn't see as orphans.
      env =
        ctx
        |> compose_env(spec.slug, Map.get(p, :compose_env, %{}))
        |> Map.put("COMPOSE_REMOVE_ORPHANS", "true")
        |> then(&if(docker_config, do: Map.put(&1, "DOCKER_CONFIG", docker_config), else: &1))

      params = %{
        workspace: paths.clone,
        config_path: Path.join(paths.clone, spec.config_path),
        config: prepared.override,
        key_order: prepared.key_order,
        # A tmpfs, for the moment compose's resolved project is on disk.
        scratch_dir: ctx.config.secrets_root,
        additional_features:
          Map.put(prepared.features, @feature_ref, Overlay.feature_options(spec.tailscale)),
        # Where install_feature/3 puts Foreman's own, which isn't in a
        # .devcontainer folder when the config is at the repo's root.
        local_feature_roots: [Path.join(config_dir(spec.config_path), ".foreman")],
        id_labels: ["foreman.env_id=#{spec.env_id}"],
        remove_existing: opts[:rebuild] == true,
        lockfile: lockfile?(paths.clone, spec.config_path),
        dotfiles: Map.get(spec, :dotfiles),
        env: env,
        state_dir: Path.join(paths.meta, "devcontainer"),
        timeout: @up_timeout
      }

      ctx.log.("info", "Starting the devcontainer\n")

      case devcontainer(ctx).up(params, ctx) do
        {:ok, up} ->
          result = %{
            "container_id" => up.container_id,
            "remote_user" => up.remote_user,
            "remote_workspace_folder" => up.remote_workspace_folder,
            "compose_project" => up.compose_project || spec.slug,
            "services" => prepared.services,
            "devcontainer_service" => prepared.devcontainer_service,
            "warnings" => prepared.warnings,
            "host_requirements" => prepared.config["hostRequirements"]
          }

          {:ok, put_feature_version(result, ctx, spec.env_id, prepared.devcontainer_service)}

        # Its own words for running out of time.
        {:error, "devcontainer up " <> _ = message} ->
          {:error, message}

        {:error, message} ->
          {:error, "devcontainer up failed: #{message}"}
      end
    end)
  end

  defp devcontainer(ctx), do: Map.get(ctx, :devcontainer, ForemanAgent.Devcontainer)

  # A devcontainer-lock.json is kept up for repos that commit one;
  # otherwise it'd be an untracked file in every workspace.
  defp lockfile?(clone, config_path) do
    relative = ForemanAgent.Devcontainer.lockfile_path(config_path)

    # There if anything is at that name, a link included: whether it can
    # be read is for bringing the devcontainer up to say. Taking one that
    # leads nowhere good for no lock file would drop the repo's pins.
    with {:ok, dir} <- SafeFS.resolve(clone, Path.dirname(relative)),
         {:ok, _stat} <- File.lstat(Path.join(dir, Path.basename(relative))) do
      true
    else
      _ -> false
    end
  end

  # Registry credentials go in a throwaway DOCKER_CONFIG for the one
  # command that needs them, never on a command line.
  defp with_docker_config(_paths, nil, fun), do: fun.(nil)
  defp with_docker_config(_paths, [], fun), do: fun.(nil)

  # On the secrets' tmpfs, never the environment's disk: that can become a
  # prebuild other people's environments start from, and a deleted file's
  # blocks stay on it.
  defp with_docker_config(paths, auths, fun) do
    dir =
      Path.join(
        Path.dirname(paths.secrets),
        ".docker-" <> (9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
      )

    File.mkdir_p!(Path.dirname(dir))
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)

    config = %{
      "auths" =>
        Map.new(auths, fn a ->
          {a.host, %{"auth" => Base.encode64("#{a.username}:#{a.token}")}}
        end)
    }

    :ok = SafeFS.write_atomic(Path.join(dir, "config.json"), JSON.encode!(config), 0o600)
    link_cli_plugins(dir)

    # Cancelling kills this process, so `after` doesn't run then; this
    # cleans up when it dies. The token is only meant to be on disk for
    # the build.
    owner = self()

    janitor =
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, _, _} -> File.rm_rf(dir)
        end
      end)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
      Process.exit(janitor, :kill)
    end
  end

  @doc """
  Removes registry credentials an agent that died mid-build left in any
  environment's directory (see `with_docker_config/3`). Runs at start,
  before any operation can be using one.
  """
  def sweep_docker_configs(config) do
    # Where earlier agents kept them, on the environment's disk.
    config.envs_root
    |> Path.join("*/meta/docker-*")
    |> Path.wildcard(match_dot: false)
    |> Enum.each(&File.rm_rf/1)

    config.secrets_root
    |> Path.join(".docker-*")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(&File.rm_rf/1)
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
      {:ok,
       result
       |> Map.take(["connect", "container_id"])
       |> Map.merge(%{"restarted" => "all", "feature_version" => result["feature_version"]})}
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
         :ok <- recreate_sidecars(ctx, paths, spec.slug, files, env, sidecars, p),
         {:ok, _} <- compose(ctx, spec.slug, ["stop", service]),
         # Recreating the devcontainer itself is ForemanAgent.Devcontainer's to do,
         # since it owns the image and labels.
         {:ok, result} <- devcontainer_up(paths, spec, prepared, p, ctx, rebuild: rebuild) do
      {:ok,
       result
       |> put_connect_hooks(ctx)
       |> Map.take(["connect", "container_id"])
       |> Map.merge(%{
         "restarted" => sidecars ++ [service],
         "feature_version" => result["feature_version"]
       })}
    end
  end

  # The recreate pulls a sidecar's image if the box doesn't have it, so it
  # gets the registry credentials bringing the devcontainer up does.
  defp recreate_sidecars(ctx, paths, slug, files, env, sidecars, p) do
    with_docker_config(paths, Map.get(p, :registry_auth), fn docker_config ->
      env = if docker_config, do: Map.put(env, "DOCKER_CONFIG", docker_config), else: env
      recreate(ctx, slug, files, env, sidecars)
    end)
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
      git = &container_git(ctx, spec, container, &1, &2)

      with {:ok, status} <- compact_status(ctx, spec, container),
           {:ok, unpushed} <-
             git.(
               [
                 "rev-list",
                 "--count",
                 "--branches",
                 "--ignore-missing",
                 "HEAD",
                 "--not",
                 "--remotes"
               ],
               "git rev-list"
             ),
           {:ok, stash} <- git.(["stash", "list", "-1", "--format=%H"], "git stash list"),
           {:ok, summary} <- git_summary(status, unpushed, stash) do
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
  @git_command ["git", "-c", "safe.directory=*", "-c", "core.fsmonitor=false"]

  defp container_git(ctx, spec, container, args, label, opts \\ []) do
    container_cmd(ctx, spec, container, @git_command ++ args, label, opts)
  end

  defp container_cmd(ctx, spec, container, args, label, opts) do
    exec = ["exec", "-u", spec.remote_user, "-w", spec.remote_workspace_folder, container | args]

    cmd(ctx, ctx.config.docker, exec,
      env: %{},
      quiet: Keyword.get(opts, :quiet, true),
      label: label
    )
  end

  # Count inside the container before the runner trims output. Git diagnostics stay
  # on stderr and a failed status propagates through the POSIX shell pipeline.
  @count_status ~S"""
  { "$@" || printf '\nFOREMAN_STATUS_FAILED\n'; } |
    awk '/^## / { branch=$0; next } /^FOREMAN_STATUS_FAILED$/ { failed=1; next }
         { count++ } END { if (failed || !branch) exit 1; print branch; print count+0 }'
  """

  defp compact_status(ctx, spec, container) do
    argv =
      ["sh", "-c", @count_status, "foreman-status"] ++
        @git_command ++ ["status", "--porcelain=v1", "--branch", "--untracked-files=normal"]

    container_cmd(ctx, spec, container, argv, "git status", [])
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

  defp git_summary(status, unpushed, stash) do
    has_stash = String.trim(stash) != ""

    with ["## " <> _ = branch_line, files] <-
           status |> String.split("\n", trim: true) |> Enum.take(-2),
         {files, ""} when files >= 0 <- Integer.parse(files),
         {commits, ""} when commits >= 0 <- Integer.parse(String.trim(unpushed)) do
      {:ok,
       %{
         "branch" => branch_name(branch_line),
         "changed_files" => files,
         "unpushed_commits" => commits,
         "ahead" => ahead(branch_line),
         "has_stash" => has_stash,
         "clean" => files == 0 and commits == 0 and not has_stash
       }}
    else
      _ -> {:error, "incomplete git status from the container"}
    end
  end

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

  defp running_container(ctx, env_id, service) do
    case devcontainer_container(ctx, env_id, service) do
      {:error, "the environment isn't running" <> _} ->
        {:error, "the environment isn't running; start it first"}

      other ->
        other
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

  # -- connect hooks -------------------------------------------------------

  # The executables in the hooks directory, by name. Missing is none.
  @list_hooks ~s(cd #{Connect.dir()} 2>/dev/null || exit 0
for f in *; do [ -f "$f" ] && [ -x "$f" ] && printf '%s\\n' "$f"; done
exit 0)

  # Runs a hook under `timeout`, or not at all: stopping docker exec
  # doesn't stop what it started in the container.
  @with_timeout ~S"""
  t=$1; shift
  command -v timeout >/dev/null 2>&1 || {
    echo '{"error":"the container has no timeout command (coreutils or busybox)"}'
    exit 125
  }
  exec timeout -k 5 "$t" "$@"
  """

  @doc false
  def hook_wrapper, do: @with_timeout

  # The hooks the devcontainer has (see `ForemanProtocol.Connect`), as
  # "connect" in every up's result, so a result without it is from an older
  # agent, which can't run them. A hook that doesn't describe itself is left
  # out and logged; a container that can't be asked has none.
  defp put_connect_hooks(%{"container_id" => container, "remote_user" => user} = result, ctx)
       when is_binary(container) and is_binary(user) do
    list = &container_exec(ctx, result, &1, :timer.seconds(@describe_seconds))
    exec = &run_hook(ctx, result, &1, @describe_seconds)

    case list.(["sh", "-c", @list_hooks]) do
      {:ok, output} ->
        names = output |> String.split("\n", trim: true) |> Enum.filter(&Connect.name?/1)

        hooks =
          names
          |> Enum.sort()
          |> Enum.take(Connect.max_hooks())
          |> Enum.flat_map(&describe_hook(&1, exec, ctx))

        Map.put(result, "connect", hooks)

      {:error, _} ->
        Map.put(result, "connect", [])
    end
  end

  defp put_connect_hooks(result, _ctx), do: Map.put(result, "connect", [])

  defp describe_hook(name, exec, ctx) do
    with {:ok, output} <- exec.([hook_path(name), "describe"]) |> describe_failed(name),
         {:ok, describe} <- last_json(output),
         {:ok, hook} <- Connect.cast_hook(name, describe) do
      [hook]
    else
      {:error, reason} ->
        ctx.log.("info", "connect hook #{name}: #{reason}\n")
        []
    end
  end

  # Runs a hook's action. What it prints is usually a secret, so none of it
  # goes to the operation's log or its error: a hook that fails can explain
  # itself with {"error": "..."} as its last line, and that alone is shown.
  defp connect(p, ctx) do
    with {:ok, spec} <- load_spec(ctx.config, p.env_id),
         {:ok, container} <- running_container(ctx, p.env_id, spec.devcontainer_service),
         where = %{
           "container_id" => container,
           "remote_user" => spec.remote_user,
           "remote_workspace_folder" => spec.remote_workspace_folder
         },
         {:ok, output} <-
           run_hook(ctx, where, [hook_path(p.hook), "run", p.action], @connect_seconds)
           |> run_failed(p.hook),
         {:ok, offer} <- connect_result(output, p.hook) do
      {:ok, %{"offer" => offer}}
    end
  end

  defp connect_result(output, hook) do
    with {:ok, json} <- last_json(output),
         {:ok, offer} <- Connect.cast_offer(json) do
      {:ok, offer}
    else
      {:error, reason} -> {:error, "connect hook #{hook} didn't print a result: #{reason}"}
    end
  end

  defp hook_path(name), do: Path.join(Connect.dir(), name)

  # A describe is a listing, so its output can say what went wrong.
  defp describe_failed({:ok, output}, _name), do: {:ok, output}
  defp describe_failed({:error, output}, _name), do: {:error, "failed: #{last_lines(output)}"}

  defp run_failed({:ok, output}, _name), do: {:ok, output}

  defp run_failed({:error, output}, name) do
    with {:ok, json} <- last_json(output),
         {:ok, error} <- Connect.cast_error(json) do
      {:error, "connect hook #{name} failed: #{error}"}
    else
      _ -> {:error, "connect hook #{name} failed"}
    end
  end

  defp run_hook(ctx, where, args, seconds) do
    exec = ["sh", "-c", @with_timeout, "sh", Integer.to_string(seconds) | args]
    container_exec(ctx, where, exec, :timer.seconds(seconds) + @hook_grace)
  end

  defp last_json(output) do
    line = output |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case List.last(line) do
      nil ->
        {:error, "no output"}

      line ->
        case JSON.decode(line) do
          {:ok, %{} = json} -> {:ok, json}
          _ -> {:error, "its last line isn't a JSON object"}
        end
    end
  end

  # As the devcontainer's remote user, in the workspace, like a shell there.
  defp container_exec(ctx, where, args, timeout) do
    exec =
      ["exec", "-u", where["remote_user"]] ++
        ["-w", where["remote_workspace_folder"] || "/", where["container_id"]] ++ args

    cmd(ctx, ctx.config.docker, exec,
      env: %{},
      quiet: true,
      timeout: timeout,
      label: "connect hook"
    )
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

  defp run_tool(ctx, command, args, opts, mapper),
    do: Logged.run(ctx, command, args, opts, mapper)

  defp timed_out(label, timeout), do: Logged.timed_out(label, timeout)

  defp last_lines(output, mapper \\ & &1), do: Logged.last_lines(output, mapper)
end
