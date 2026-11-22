defmodule ForemanAgent.Devcontainer do
  @moduledoc """
  Brings a compose-based devcontainer up, as the devcontainer CLI's `up`
  does: builds the devcontainer service's image with its features on top,
  creates the containers with what the config and the features ask for,
  and runs the lifecycle commands in the devcontainer.

  It follows the CLI (v0.90) closely enough that either can take over an
  environment the other made: the same Dockerfile, compose overrides,
  image names, labels, marker files and install order. What it leaves out
  is what Foreman never used: devcontainers that aren't compose-based,
  Podman, builds without BuildKit, GPUs, and the two feature formats the
  CLI calls deprecated.

  The files it writes go in `state_dir`, which has to outlive the
  containers: a stopped container is started again with the compose files
  it was created with.

      state_dir/build/      the features, and the Dockerfile that installs them
      state_dir/compose/    the build and start overrides
      state_dir/empty/      a build context with nothing in it

  Portions are adapted from the devcontainer CLI, which is MIT licensed
  (see `priv/licenses/devcontainers-cli.txt`).
  """

  alias ForemanAgent.Devcontainer.{Compose, Dockerfile, Features, Lifecycle, Metadata, Substitute}
  alias ForemanAgent.Devcontainer.Features.{Build, Control, Registry}
  alias ForemanAgent.Runner.{Local, Logged}
  alias ForemanAgent.SafeFS

  @type params :: %{
          optional(:uid) => {non_neg_integer(), non_neg_integer()} | nil | :detect,
          optional(:key_order) => %{String.t() => [String.t()]},
          optional(:scratch_dir) => Path.t(),
          optional(:local_feature_roots) => [Path.t()],
          optional(:control) => (-> Control.t()),
          workspace: Path.t(),
          config_path: Path.t(),
          config: map(),
          additional_features: map(),
          id_labels: [String.t()],
          remove_existing: boolean(),
          lockfile: boolean(),
          dotfiles: map() | nil,
          env: %{String.t() => String.t()},
          state_dir: Path.t(),
          timeout: non_neg_integer()
        }

  @type result :: %{
          container_id: String.t(),
          remote_user: String.t(),
          remote_workspace_folder: String.t(),
          compose_project: String.t()
        }

  @callback up(params(), map()) :: {:ok, result()} | {:error, String.t()}

  @behaviour __MODULE__

  @project_label "com.docker.compose.project"
  @service_label "com.docker.compose.service"
  @config_files_label "com.docker.compose.project.config_files"
  @build_prefix "docker-compose.devcontainer.build"
  @start_prefix "docker-compose.devcontainer.containerFeatures"
  @default_stage "dev_container_auto_added_stage_label"
  @max_dockerfile 1_000_000

  @doc """
  Brings the devcontainer up. `params`:

    * `:workspace` - the repo's clone, which commands outside the containers run in
    * `:config_path` - the devcontainer.json's path in it
    * `:config` - the devcontainer.json, decoded, with `dockerComposeFile`
      as the absolute paths of every compose file to use
    * `:key_order` - the order `containerEnv`'s keys are written in
    * `:scratch_dir` - somewhere that isn't kept (a tmpfs) for compose's
      resolved project, which holds interpolated secrets for the moment
      it's read; `state_dir` without one
    * `:additional_features` - features to install besides the config's (id => options)
    * `:local_feature_roots` - folders in the workspace, besides `.devcontainer`,
      that a feature named by a path may be in
    * `:id_labels` - `name=value` labels that mark the devcontainer's container
    * `:remove_existing` - whether to replace a container that exists
    * `:lockfile` - whether to keep `devcontainer-lock.json` next to the config
    * `:dotfiles` - `%{repository:, install_command:, target_path:}` or nil
    * `:env` - the environment docker runs with (and `${localEnv:...}` reads)
    * `:state_dir` - where its files go
    * `:timeout` - how long all of it may take, in milliseconds
    * `:uid` - `{uid, gid}` to give the remote user, nil to leave it; by
      default the agent's own, on Linux
    * `:control` - a function that gives the control manifest
      (`Features.Control`); by default it's fetched, with a copy in the
      agent's data directory
  """
  @impl true
  def up(params, ctx) do
    state = %{
      ctx: ctx,
      params: params,
      env: params.env,
      deadline: System.monotonic_time(:millisecond) + params.timeout
    }

    with {:ok, config} <- substituted(params),
         state =
           Map.merge(state, %{raw: old_properties(params.config), config: old_properties(config)}),
         :ok <- allowed(state),
         :ok <- initialize(state),
         {:ok, compose} <- compose_config(state),
         {:ok, service} <- service(state, compose),
         project = project_name(state, compose),
         state = Map.merge(state, %{compose: compose, service: service, project: project}),
         {:ok, container} <- find_container(state),
         {:ok, container} <- remove(state, container),
         {:ok, container} <- ensure_running(state, container),
         entries =
           substitute!(Metadata.from_container(container, state.raw, params.id_labels), state),
         merged = Metadata.merge(state.config, entries),
         {:ok, %{remote_user: remote_user}} <-
           Lifecycle.run(
             %{
               container: container,
               merged: merged,
               origins: Metadata.lifecycle_origins(entries),
               remote_workspace_folder: workspace_folder(state.config),
               dotfiles: params[:dotfiles],
               env: state.env,
               deadline: state.deadline,
               timed_out: timed_out(state)
             },
             ctx
           ) do
      {:ok,
       %{
         container_id: container["Id"],
         remote_user: remote_user,
         remote_workspace_folder: workspace_folder(state.config),
         compose_project: project
       }}
    end
  catch
    {:devcontainer_error, message} -> {:error, message}
  end

  defp workspace_folder(config), do: config["workspaceFolder"] || "/"

  # -- the config ----------------------------------------------------------

  defp substituted(params) do
    context = %{
      local_workspace_folder: params.workspace,
      container_workspace_folder: workspace_folder(params.config),
      env: Local.visible_env(params.env)
    }

    with {:ok, config} <- Substitute.local(params.config, context) do
      {:ok, Substitute.devcontainer_id(config, params.id_labels)}
    end
  end

  # Metadata entries are kept as written; this is what the variables in
  # them come to here.
  defp substitute!(value, state) do
    context = %{
      local_workspace_folder: state.params.workspace,
      container_workspace_folder: workspace_folder(state.params.config),
      env: Local.visible_env(state.env)
    }

    case Substitute.local(value, context) do
      {:ok, value} -> Substitute.devcontainer_id(value, state.params.id_labels)
      {:error, message} -> fail(message)
    end
  end

  # A devcontainer.json once listed VS Code's extensions and settings at the top.
  defp old_properties(config) do
    if Enum.any?(["extensions", "settings", "devPort"], &Map.has_key?(config, &1)) do
      customizations =
        if is_map(config["customizations"]), do: config["customizations"], else: %{}

      vscode = if is_map(customizations["vscode"]), do: customizations["vscode"], else: %{}

      vscode =
        vscode
        |> then(fn v ->
          if is_list(config["extensions"]),
            do: Map.put(v, "extensions", List.wrap(v["extensions"]) ++ config["extensions"]),
            else: v
        end)
        |> then(fn v ->
          if is_map(config["settings"]),
            do: Map.put(v, "settings", Map.merge(config["settings"], v["settings"] || %{})),
            else: v
        end)
        |> then(fn v ->
          if Map.has_key?(config, "devPort") and not Map.has_key?(v, "devPort"),
            do: Map.put(v, "devPort", config["devPort"]),
            else: v
        end)

      config
      |> Map.drop(["extensions", "settings", "devPort"])
      |> Map.put("customizations", Map.put(customizations, "vscode", vscode))
    else
      config
    end
  end

  # -- features the devcontainers project has pulled -------------------------

  defp control(state) do
    case state.params[:control] do
      nil ->
        Control.load(
          Path.join([state.ctx.config.data_dir, "devcontainer", "control-manifest.json"])
        )

      load ->
        load.()
    end
  end

  # A feature reported as harmful isn't installed, and a devcontainer that
  # has it doesn't keep running.
  defp allowed(state) do
    ids =
      for {id, _} <-
            Features.user_features(state.config["features"], state.params.additional_features),
          do: id

    case Control.disallowed(control(state), ids) do
      nil ->
        :ok

      %{id: id, documentation_url: url} ->
        stopped =
          with {:ok, [_ | _] = containers} <-
                 state.ctx.docker.list_containers(state.params.id_labels),
               # Its sidecars carry the same labels; they aren't what's built with the feature.
               running =
                 for(
                   %{"State" => "running", "Id" => id, "Labels" => %{@service_label => service}} <-
                     containers,
                   service == state.config["service"],
                   do: id
                 ),
               true <- running != [],
               {:ok, %{status: 0}} <-
                 run(
                   state,
                   docker(state),
                   ["stop", "-t", "0" | running],
                   [label: "docker stop"],
                   fn _ -> nil end
                 ) do
            " The devcontainer was stopped."
          else
            _ -> ""
          end

        {:error,
         "the feature #{id} was reported as harmful and can't be used. Remove it from the devcontainer.json and rebuild." <>
           stopped <> if(url, do: " See #{url}", else: "")}
    end
  end

  # -- initializeCommand ---------------------------------------------------

  # Runs outside the containers, in the workspace, before anything is built.
  defp initialize(state) do
    case state.config["initializeCommand"] do
      command when is_binary(command) ->
        if String.trim(command) == "",
          do: :ok,
          else: initialize(state, [{nil, ["/bin/sh", "-c", command]}])

      [_ | _] = argv ->
        initialize(state, [{nil, argv(state, argv)}])

      %{} = named when map_size(named) > 0 ->
        initialize(
          state,
          for {name, command} <- Enum.sort(named), runnable?(command) do
            {name,
             if(is_binary(command), do: ["/bin/sh", "-c", command], else: argv(state, command))}
          end
        )

      _ ->
        :ok
    end
  end

  defp runnable?(command) when is_binary(command), do: String.trim(command) != ""
  defp runnable?([_ | _]), do: true
  defp runnable?(_command), do: false

  # A command given as a list runs without a shell, in the workspace: a
  # path there (`./scripts/setup`) is found from it, not from PATH.
  defp argv(state, [command | args]) do
    command = to_string(command)

    command =
      if String.contains?(command, "/") and Path.type(command) == :relative,
        do: Path.expand(command, state.params.workspace),
        else: command

    [command | Enum.map(args, &to_string/1)]
  end

  defp initialize(state, [{nil, [command | args]}]) do
    state.ctx.log.("info", "Running the initializeCommand from devcontainer.json...\n")

    case run(
           state,
           command,
           args,
           [cd: state.params.workspace, label: "the initializeCommand"],
           & &1
         ) do
      {:ok, %{status: 0}} -> :ok
      {:ok, %{status: status}} -> {:error, initialize_failed(status)}
      {:error, message} -> {:error, message}
    end
  end

  defp initialize(_state, []), do: :ok

  defp initialize(state, named) do
    named
    |> Enum.map(fn {name, [command | args]} ->
      Task.async(fn ->
        result =
          run(
            state,
            command,
            args,
            [cd: state.params.workspace, label: "the initializeCommand"],
            fn _ -> nil end
          )

        output =
          case result do
            {:ok, %{output: output}} -> Logged.shown(output)
            _ -> ""
          end

        state.ctx.log.("info", "Running '#{name}' from initializeCommand...\n#{output}\n")
        result
      end)
    end)
    |> Task.await_many(:infinity)
    |> Enum.find_value(:ok, fn
      {:ok, %{status: 0}} -> nil
      {:ok, %{status: status}} -> {:error, initialize_failed(status)}
      {:error, message} -> {:error, message}
    end)
  end

  defp initialize_failed(status),
    do: "the initializeCommand in the devcontainer.json failed with exit code #{status}"

  # -- compose -------------------------------------------------------------

  defp compose_files(state), do: List.wrap(state.config["dockerComposeFile"])

  defp file_args(files), do: Enum.flat_map(files, &["-f", &1])

  # Compose's own view of the files, every profile included, read here
  # (after the initialize command, which can change it) and not taken from
  # an earlier look. It holds the values compose interpolated, secrets
  # among them, so it's read from a file that's gone again at once and
  # never logged.
  defp compose_config(state) do
    dir = state.params[:scratch_dir] || state.params.state_dir
    File.mkdir_p!(dir)
    name = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    # Named so ForemanAgent.Env.sweep_docker_configs/1 removes one left by
    # an agent that died here.
    out = Path.join(dir, ".docker-compose-#{name}.json")

    args =
      ["compose"] ++
        file_args(compose_files(state)) ++
        ["--profile", "*", "config", "--format", "json", "-o", out]

    result =
      case run(state, docker(state), args, [label: "docker compose config"], fn _ -> nil end) do
        {:ok, %{status: 0}} ->
          with {:ok, content} <- File.read(out),
               {:ok, %{} = config} <- JSON.decode(content) do
            {:ok, config}
          else
            _ -> {:error, "couldn't read docker compose config's output"}
          end

        {:ok, _} ->
          {:error, "docker compose config failed"}

        {:error, message} ->
          {:error, message}
      end

    File.rm(out)
    result
  end

  defp service(state, compose) do
    name = state.config["service"]

    case compose["services"] do
      %{^name => %{} = service} -> {:ok, service}
      _ -> {:error, "the service '#{name}' in the devcontainer.json isn't in the compose files"}
    end
  end

  defp project_name(state, compose) do
    case Compose.project_name(state.env["COMPOSE_PROJECT_NAME"] || "") do
      "" -> Compose.project_name(compose["name"] || Path.basename(state.params.workspace))
      name -> name
    end
  end

  defp run_services(state) do
    service = state.config["service"]

    case state.config["runServices"] do
      [_ | _] = services -> services ++ if(service in services, do: [], else: [service])
      _ -> []
    end
  end

  # -- the container -------------------------------------------------------

  defp find_container(state) do
    labels = [
      "#{@project_label}=#{state.project}",
      "#{@service_label}=#{state.config["service"]}"
    ]

    case state.ctx.docker.list_containers(labels) do
      {:ok, [%{"Id" => id} | _]} ->
        inspect_container(state, id)

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, "couldn't list the environment's containers: #{inspect(reason)}"}
    end
  end

  defp inspect_container(state, id) do
    case state.ctx.docker.inspect_container(id) do
      {:ok, container} -> {:ok, container}
      {:error, reason} -> {:error, "couldn't inspect the devcontainer: #{inspect(reason)}"}
    end
  end

  defp remove(%{params: %{remove_existing: true}} = state, %{"Id" => id}) do
    state.ctx.log.("info", "Removing the existing container\n")

    case run(state, docker(state), ["rm", "-f", id], [label: "docker rm"], fn _ -> nil end) do
      {:ok, %{status: 0}} ->
        {:ok, nil}

      {:ok, %{output: output}} ->
        {:error, "removing the container failed: #{Logged.last_lines(output)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp remove(_state, container), do: {:ok, container}

  defp ensure_running(_state, %{"State" => %{"Status" => "running"}} = container),
    do: {:ok, container}

  defp ensure_running(state, container) do
    with {:ok, overrides} <- overrides(state, container),
         :ok <- compose_up(state, overrides, container),
         {:ok, %{} = container} <- find_container(state) do
      {:ok, container}
    else
      {:ok, nil} ->
        {:error, "docker compose up didn't start the service '#{state.config["service"]}'"}

      {:error, message} ->
        {:error, message}
    end
  end

  # The override files to start with: the ones a container that exists was
  # created with, if they're still there; else new ones (and for a new
  # container, a build).
  defp overrides(state, container) do
    case container && persisted(container) do
      [_ | _] = files -> {:ok, files}
      _ -> generate(state, container)
    end
  end

  defp persisted(container) do
    files = String.split(get_in(container, ["Config", "Labels", @config_files_label]) || "", ",")
    build = Enum.find(files, &String.contains?(&1, @build_prefix))
    start = Enum.find(files, &String.contains?(&1, @start_prefix))

    if is_binary(start) and File.regular?(start) and (is_nil(build) or File.regular?(build)),
      do: Enum.reject([build, start], &is_nil/1),
      else: nil
  end

  defp generate(state, container) do
    build? = is_nil(container)
    dir = state.params.state_dir
    for sub <- ["build", "compose"], do: clear(Path.join(dir, sub))
    for sub <- ["build", "compose", "empty"], do: File.mkdir_p!(Path.join(dir, sub))
    original = state.service["image"] || "#{state.project}-#{state.config["service"]}"

    with {:ok, extended} <- extend(state, build?),
         current = extended.image || original,
         merged = Metadata.merge(state.config, substitute!(extended.entries, state)),
         {:ok, image} <- image_details(state, current),
         {:ok, updated} <- uid_image(state, merged, current, image, build?) do
      replaced = if updated != original, do: updated
      {:ok, extended.files ++ [write_start(state, merged, image, extended.labels, replaced)]}
    end
  end

  # What an archive unpacked can have modes that keep even its owner out.
  defp clear(path) do
    with {:error, _, _} <- File.rm_rf(path) do
      {_, _} = System.cmd("chmod", ["-R", "u+rwx", path], stderr_to_stdout: true)
      File.rm_rf!(path)
    end
  end

  # A container that exists keeps the image it has.
  defp uid_image(_state, _merged, current, _image, false), do: {:ok, current}

  defp uid_image(state, merged, current, image, true),
    do: update_uid(state, merged, current, image)

  defp write_start(state, merged, image, labels, image_name) do
    {entrypoint, command} =
      Compose.user_commands(state.service, image["Config"] || %{}, merged["overrideCommand"])

    start =
      Compose.start_override(%{
        version_prefix: version_prefix(state),
        service: state.config["service"],
        image: image_name,
        entrypoints: merged["entrypoints"] || [],
        user_entrypoint: entrypoint,
        command: command,
        init: merged["init"],
        user: merged["containerUser"],
        env: merged["containerEnv"] || %{},
        privileged: merged["privileged"],
        cap_add: merged["capAdd"] || [],
        security_opt: merged["securityOpt"] || [],
        labels:
          state.params.id_labels ++ Enum.map(labels, fn {name, value} -> "#{name}=#{value}" end),
        mounts: merged["mounts"] || []
      })

    name = "#{@start_prefix}-#{System.os_time(:millisecond)}-#{uuid()}.yml"
    path = Path.join([state.params.state_dir, "compose", name])
    File.write!(path, start)
    path
  end

  defp compose_up(state, overrides, container) do
    state.ctx.log.("info", "Starting the containers\n")

    args =
      ["compose", "--project-name", state.project] ++
        file_args(compose_files(state) ++ overrides) ++
        ["up", "-d"] ++ if(container, do: ["--no-recreate"], else: []) ++ run_services(state)

    case run(state, docker(state), args, [label: "docker compose up"], & &1) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{output: output}} ->
        {:error, "starting the containers failed: #{Logged.last_lines(output)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  # -- the image -----------------------------------------------------------

  # The service's image with the features installed and the metadata label
  # on it: the files that build it, and the build unless `build?` is false.
  defp extend(state, build?) do
    dst = Path.join(state.params.state_dir, "build")
    service_build = Compose.service_build(state.service, compose_files(state))

    with {:ok, base} <- base(state, service_build),
         {:ok, sets} <- features(state, dst) do
      entries = Metadata.build(base.entries, sets, state.raw)

      if sets == [] and is_nil(service_build) do
        # Nothing to build: the label goes on the container.
        labels = [{Metadata.label_name(), Metadata.label_value(entries)}]
        {:ok, %{entries: entries, files: [], image: nil, labels: labels}}
      else
        extend_image(
          state,
          base,
          feature_build(state, base, sets, entries, dst),
          service_build,
          entries,
          build?
        )
      end
    end
  end

  defp extend_image(state, base, build, service_build, entries, build?) do
    dir = state.params.state_dir
    image = if is_nil(service_build), do: folder_image(state)
    dockerfile = base.dockerfile || "FROM #{state.service["image"]} AS #{base.name}\n"
    path = Path.join([dir, "build", "Dockerfile-with-features"])
    File.write!(path, build.prefix <> strip_syntax(dockerfile) <> "\n" <> build.content)

    override =
      Compose.build_override(%{
        version_prefix: version_prefix(state),
        service: state.config["service"],
        dockerfile: path,
        build: build,
        service_build: service_build,
        image: image,
        empty_context: Path.join(dir, "empty")
      })

    file = Path.join([dir, "compose", "#{@build_prefix}-#{System.os_time(:millisecond)}.yml"])
    File.write!(file, override)

    with :ok <- if(build?, do: compose_build(state, file), else: :ok) do
      {:ok, %{entries: entries, files: [file], image: image, labels: []}}
    end
  end

  # With no features, the image still gets its metadata label.
  defp feature_build(_state, base, [], entries, _dst),
    do: Build.label_only(base.name, entries, base.syntax)

  defp feature_build(state, base, sets, entries, dst) do
    {container_user, remote_user} =
      users(substitute!(entries, state), state.service["user"], base.user)

    Build.write_files(sets, dst, container_user, remote_user)

    Build.dockerfile(sets,
      dst: dst,
      base_name: base.name,
      image_user: base.user,
      container_user: container_user,
      remote_user: remote_user,
      metadata: entries,
      container_env: state.config["containerEnv"],
      container_env_order: get_in(state.params, [:key_order, "containerEnv"]),
      syntax: base.syntax
    )
  end

  defp compose_build(state, override) do
    state.ctx.log.("info", "Building the devcontainer's image\n")

    args =
      ["compose", "--project-name", state.project] ++
        file_args(compose_files(state) ++ [override]) ++ ["build"] ++ run_services(state)

    case run(state, docker(state), args, [label: "docker compose build", keep: 262_144], & &1) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{output: output}} ->
        {:error, "building the devcontainer's image failed: #{Logged.last_lines(output)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  # What the features go on top of: the stage to extend, who it runs as,
  # and the metadata of the image under it.
  defp base(state, nil) do
    with {:ok, image} <- image_details(state, state.service["image"]) do
      {:ok,
       %{
         name: @default_stage,
         dockerfile: nil,
         syntax: nil,
         user: non_empty(get_in(image, ["Config", "User"])) || "root",
         entries: Metadata.from_labels(get_in(image, ["Config", "Labels"]))
       }}
    end
  end

  defp base(state, service_build) do
    with {:ok, text} <- read_dockerfile(state, service_build.dockerfile_path),
         {:ok, name, modified} <- stage_name(state, text, service_build.target) do
      parsed = Dockerfile.parse(text)
      platform = platform_args(state)

      base_image =
        Dockerfile.find_base_image(parsed, service_build.args, service_build.target, platform)

      with {:ok, image} <- if(base_image, do: image_details(state, base_image), else: {:ok, %{}}) do
        image_env =
          for pair <- get_in(image, ["Config", "Env"]) || [],
              [key, value] <- [String.split(pair, "=", parts: 2)],
              into: %{},
              do: {key, value}

        user =
          Dockerfile.find_user(
            parsed,
            service_build.args,
            image_env,
            platform,
            service_build.target
          ) ||
            non_empty(get_in(image, ["Config", "User"])) || "root"

        {:ok,
         %{
           name: name,
           dockerfile: modified || text,
           syntax: parsed.preamble.directives["syntax"],
           user: user,
           entries: Metadata.from_labels(get_in(image, ["Config", "Labels"]))
         }}
      end
    end
  end

  defp stage_name(_state, _text, target) when is_binary(target), do: {:ok, target, nil}

  defp stage_name(state, text, nil) do
    case Dockerfile.ensure_final_stage_name(text, @default_stage) do
      {:ok, name, modified} ->
        {:ok, name, modified}

      {:error, message} ->
        {:error,
         "the Dockerfile of the service '#{state.config["service"]}' can't be built on: #{message}"}
    end
  end

  # Inside the clone, without following a link out of it: the repo names the path.
  defp read_dockerfile(state, path) do
    relative = Path.relative_to(path, Path.expand(state.params.workspace))

    with :relative <- Path.type(relative),
         {:ok, content} <-
           SafeFS.read(state.params.workspace, relative, max_bytes: @max_dockerfile) do
      {:ok, content}
    else
      {:error, :enoent} ->
        {:error, "the Dockerfile of the service '#{state.config["service"]}' wasn't found"}

      _ ->
        {:error,
         "the Dockerfile of the service '#{state.config["service"]}' has to be in the repository"}
    end
  end

  # The line would come second, after the one this adds.
  defp strip_syntax(dockerfile),
    do: Regex.replace(~r/\A\s*#\s*syntax\s*=.*[\r\n]/, dockerfile, "")

  defp non_empty(value) when value in [nil, ""], do: nil
  defp non_empty(value), do: value

  # BuildKit's platform arguments, which a FROM can use.
  defp platform_args(state) do
    case state.ctx.docker.info() do
      {:ok, %{"OSType" => os, "Architecture" => arch}} ->
        arch = Map.get(%{"x86_64" => "amd64", "aarch64" => "arm64"}, arch, arch)

        %{
          "BUILDPLATFORM" => "#{os}/#{arch}",
          "BUILDOS" => os,
          "BUILDARCH" => arch,
          "BUILDVARIANT" => "",
          "TARGETPLATFORM" => "#{os}/#{arch}",
          "TARGETOS" => os,
          "TARGETARCH" => arch,
          "TARGETVARIANT" => ""
        }

      _ ->
        %{}
    end
  end

  # An image's details, pulling it first when the box doesn't have it.
  defp image_details(state, name) do
    case state.ctx.docker.inspect_image(name) do
      {:ok, image} ->
        {:ok, image}

      {:error, _} ->
        state.ctx.log.("info", "Pulling #{name}\n")

        with {:ok, %{status: 0}} <-
               run(state, docker(state), ["pull", name], [label: "docker pull"], & &1),
             {:ok, image} <- state.ctx.docker.inspect_image(name) do
          {:ok, image}
        else
          {:ok, %{output: output}} ->
            {:error, "pulling #{name} failed: #{Logged.last_lines(output)}"}

          {:error, message} when is_binary(message) ->
            {:error, message}

          {:error, reason} ->
            {:error, "couldn't inspect the image #{name}: #{inspect(reason)}"}
        end
    end
  end

  # The name of an image built for a service that names its own.
  defp folder_image(state) do
    workspace = state.params.workspace
    hash = Base.encode16(:crypto.hash(:sha256, workspace), case: :lower)
    image_name("vsc-#{Path.basename(workspace)}-#{hash}")
  end

  defp image_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "")
    |> then(
      &Regex.replace(~r/(\.[._-]|_[.-]|__[._-]|-+[._])[._-]*/, &1, fn _, a ->
        String.slice(a, 0..-2//1)
      end)
    )
  end

  defp users(entries, service_user, image_user) do
    reversed = Enum.reverse(entries)

    container_user =
      Enum.find_value(reversed, & &1["containerUser"]) || non_empty(service_user) || image_user

    {container_user, Enum.find_value(reversed, & &1["remoteUser"]) || container_user}
  end

  # The first compose file is the repo's, and by now the repo's own
  # commands have run: read like anything else in the workspace.
  defp version_prefix(state) do
    workspace = Path.expand(state.params.workspace)

    with [first | _] <- compose_files(state),
         relative = Path.relative_to(first, workspace),
         :relative <- Path.type(relative),
         {:ok, content} <- SafeFS.read(workspace, relative, max_bytes: @max_dockerfile) do
      Compose.version_prefix(content)
    else
      _ -> ""
    end
  end

  # -- features ------------------------------------------------------------

  defp features(state, dst) do
    params = state.params

    lockfile_path =
      lockfile_path(Path.relative_to(params.config_path, Path.expand(params.workspace)))

    with {:ok, lockfile} <- current_lockfile(params, lockfile_path),
         {:ok, sets} <- prepare_features(state, dst, lockfile),
         :ok <- keep_lockfile(state, lockfile_path, sets, lockfile) do
      case Control.advisories(control(state), sets) do
        [] -> :ok
        found -> state.ctx.log.("info", Control.describe(found))
      end

      {:ok, sets}
    end
  end

  # Getting features is downloads and unpacking, with no command of its
  # own to time out. It runs in a task that's stopped at the deadline,
  # whatever it's in the middle of.
  defp prepare_features(state, dst, lockfile) do
    params = state.params
    log = &state.ctx.log.("info", &1 <> "\n")
    auths = auths(state)

    task =
      Task.async(fn ->
        opts = [
          workspace: params.workspace,
          config_path: params.config_path,
          # Its tokens are kept in the process that makes it.
          registry: Registry.new(auths: auths, log: log, deadline: state.deadline),
          local_roots: params[:local_feature_roots],
          lockfile: lockfile,
          github_token: Registry.github_token(state.env),
          deadline: state.deadline,
          log: log
        ]

        Features.prepare(state.config, params.additional_features, dst, opts)
      end)

    left = max(state.deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, left) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, sets}} ->
        {:ok, sets}

      {:ok, {:error, message}} ->
        {:error, if(past_deadline?(state), do: timed_out(state), else: message)}

      _ ->
        {:error, timed_out(state)}
    end
  end

  defp past_deadline?(state), do: System.monotonic_time(:millisecond) >= state.deadline

  defp current_lockfile(%{lockfile: true} = params, path),
    do: read_lockfile(params.workspace, path)

  defp current_lockfile(_params, _path), do: {:ok, nil}

  defp keep_lockfile(%{params: %{lockfile: true} = params} = state, path, [_ | _] = sets, current) do
    content = Features.lockfile(sets, state.config, params.additional_features)

    cond do
      JSON.decode!(content) == current -> :ok
      # Nothing in the repo changes for an operation that's over.
      past_deadline?(state) -> {:error, timed_out(state)}
      true -> write_lockfile(params.workspace, path, content)
    end
  end

  defp keep_lockfile(_state, _path, _sets, _current), do: :ok

  @doc """
  Where a devcontainer.json's lock file is: next to it, hidden when the
  config is (`.devcontainer.json` has `.devcontainer-lock.json`).
  """
  @spec lockfile_path(Path.t()) :: Path.t()
  def lockfile_path(config_path) when is_binary(config_path) do
    name =
      if String.starts_with?(Path.basename(config_path), "."),
        do: ".devcontainer-lock.json",
        else: "devcontainer-lock.json"

    Path.join(Path.dirname(config_path), name)
  end

  # An empty file asks for a lock file to be started. One that's there
  # and can't be read is an error: carrying on would pull whatever the
  # tags point at now, and write that over it.
  defp read_lockfile(workspace, relative) do
    case SafeFS.read(workspace, relative, max_bytes: @max_dockerfile) do
      {:ok, content} ->
        case {String.trim(content), JSON.decode(content)} do
          {"", _} ->
            {:ok, nil}

          {_, {:ok, %{} = lockfile}} ->
            if valid_pins?(Map.get(lockfile, "features", %{})),
              do: {:ok, lockfile},
              else: {:error, "#{relative} has invalid feature pins; fix or delete it"}

          _ ->
            {:error, "#{relative} isn't valid JSON; fix or delete it"}
        end

      {:error, :enoent} ->
        # Nothing there, or a link to nothing: writing would replace the link.
        with {:ok, dir} <- SafeFS.resolve(workspace, Path.dirname(relative)),
             {:ok, %File.Stat{type: :symlink}} <-
               File.lstat(Path.join(dir, Path.basename(relative))) do
          {:error, "#{relative} is a link that leads nowhere"}
        else
          _ -> {:ok, nil}
        end

      {:error, reason} ->
        {:error, "couldn't read #{relative}: #{inspect(reason)}"}
    end
  end

  defp valid_pins?(features) when is_map(features) do
    Enum.all?(features, fn
      {_, %{"integrity" => digest}} -> is_binary(digest)
      {_, entry} -> is_map(entry)
    end)
  end

  defp valid_pins?(_), do: false

  # Written only when it would change, so a repo's own stays as committed.
  # Into the file the path really leads to: a lock file, or a .devcontainer
  # folder, that's a link to elsewhere in the repo stays one.
  defp write_lockfile(workspace, relative, content) do
    target =
      case SafeFS.resolve(workspace, relative) do
        {:ok, path} ->
          {:ok, path}

        {:error, :enoent} ->
          with {:ok, dir} <- SafeFS.resolve(workspace, Path.dirname(relative)),
               do: {:ok, Path.join(dir, Path.basename(relative))}

        error ->
          error
      end

    with {:ok, path} <- target,
         :ok <- SafeFS.write_atomic(path, content, 0o644) do
      :ok
    else
      {:error, reason} -> {:error, "couldn't write #{relative}: #{inspect(reason)}"}
    end
  end

  # The registry credentials docker was given for this, and any the
  # environment carries the way the devcontainer CLI reads them.
  defp auths(state) do
    docker =
      with dir when is_binary(dir) <- state.env["DOCKER_CONFIG"],
           {:ok, content} <- File.read(Path.join(dir, "config.json")),
           {:ok, %{"auths" => %{} = auths}} <- JSON.decode(content) do
        auths
      else
        _ -> %{}
      end

    Registry.auths(docker, state.env)
  end

  # -- the remote user's uid -----------------------------------------------

  # Bind-mounted files belong to whoever runs the agent; the remote user
  # gets that uid and gid, in an image on top, so they're its own.
  defp update_uid(state, merged, image_name, image) do
    image_user = non_empty(get_in(image, ["Config", "User"])) || "root"
    remote_user = merged["remoteUser"] || non_empty(state.service["user"]) || image_user

    with true <- merged["updateRemoteUserUID"] != false,
         false <- remote_user == "root" or Regex.match?(~r/^\d+$/, remote_user),
         {uid, gid} <- uid(state) do
      folder = folder_image(state)
      fixed = if(String.starts_with?(image_name, folder), do: image_name, else: folder) <> "-uid"
      state.ctx.log.("info", "Giving #{remote_user} the uid #{uid}\n")

      build_args = [
        "BASE_IMAGE=#{image_name}",
        "REMOTE_USER=#{remote_user}",
        "NEW_UID=#{uid}",
        "NEW_GID=#{gid}",
        "IMAGE_USER=#{image_user}"
      ]

      case run(
             state,
             docker(state),
             uid_build(state, fixed, image, build_args),
             [label: "docker build"],
             & &1
           ) do
        {:ok, %{status: 0}} ->
          {:ok, fixed}

        {:ok, %{output: output}} ->
          {:error, "updating #{remote_user}'s uid failed: #{Logged.last_lines(output)}"}

        {:error, message} ->
          {:error, message}
      end
    else
      _ -> {:ok, image_name}
    end
  end

  defp uid_build(state, tag, image, build_args) do
    dockerfile = Path.join(state.params.state_dir, "updateUID.Dockerfile")
    source = Application.app_dir(:foreman_agent, "priv/devcontainer/updateUID.Dockerfile")
    File.write!(dockerfile, File.read!(source))

    platform =
      case Enum.reject([image["Os"], image["Architecture"], image["Variant"]], &(&1 in [nil, ""])) do
        [] -> []
        parts -> ["--platform", Enum.join(parts, "/")]
      end

    ["build", "-f", dockerfile, "-t", tag] ++
      platform ++
      Enum.flat_map(build_args, &["--build-arg", &1]) ++
      [Path.join(state.params.state_dir, "empty")]
  end

  defp uid(state) do
    case Map.get(state.params, :uid, :detect) do
      :detect ->
        with {:unix, :linux} <- :os.type(),
             {:ok, %{status: 0, output: uid}} <- run(state, "id", ["-u"], [], fn _ -> nil end),
             {:ok, %{status: 0, output: gid}} <- run(state, "id", ["-g"], [], fn _ -> nil end),
             {uid, ""} <- Integer.parse(String.trim(uid)),
             {gid, ""} <- Integer.parse(String.trim(gid)) do
          {uid, gid}
        else
          _ -> nil
        end

      other ->
        other
    end
  end

  # -- commands ------------------------------------------------------------

  defp docker(state), do: state.ctx.config.docker

  defp run(state, command, args, opts, mapper) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, timed_out(state)}
    else
      opts =
        Keyword.merge([env: state.env, timeout: remaining, timed_out: timed_out(state)], opts)

      Logged.run(state.ctx, command, args, opts, mapper)
    end
  end

  defp timed_out(state), do: Logged.timed_out("devcontainer up", state.params.timeout)

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message), do: throw({:devcontainer_error, message})
end
