defmodule ForemanAgent.Env.Policy do
  @moduledoc """
  Checks an environment's merged compose config (and its devcontainer.json)
  before the agent starts it.

  A repo's compose files can bind any host path into a container, read any
  host file into a container's environment, or share the host's network.
  Repos are trusted to the level of the box they run on, but a compose file
  in the workspace can be rewritten by anything running inside the
  environment, so the agent checks it on every start, not just the first.

  Some things are refused no matter what the box allows: binds and host
  files that expose the agent's own state, other environments, or secrets
  directories. Everything else is a rule with an action per box: `:refuse`,
  `:warn` or `:allow`. Every rule refuses unless the box opts out (see
  `ForemanProtocol.Policy`).

  Features can ask for privileges in their own metadata, so `check/3`
  covers the repo's files and `check_resolved/2` covers what the
  devcontainer CLI resolves, features included.
  """

  alias ForemanAgent.SafeFS

  @default_rules Map.new(ForemanProtocol.Policy.defaults(), fn {rule, action} ->
                   {String.to_atom(rule), String.to_atom(action)}
                 end)

  # Capabilities that are root on the box from inside a container.
  @root_caps ~w(ALL SYS_ADMIN SYS_MODULE SYS_RAWIO DAC_READ_SEARCH BPF PERFMON MAC_ADMIN)

  @allowed_devices ["/dev/net/tun"]
  @docker_sockets ["/run/docker.sock", "/var/run/docker.sock"]

  # Namespace settings, and what to call them in a finding.
  @namespaces [
    {"network_mode", "network"},
    {"pid", "PID namespace"},
    {"ipc", "IPC namespace"},
    {"uts", "UTS namespace"},
    {"cgroup", "cgroup namespace"},
    {"userns_mode", "user namespace"}
  ]

  def default_rules, do: @default_rules

  @type ctx :: %{
          workspace_root: Path.t(),
          secrets_dir: Path.t(),
          protected: [Path.t()],
          rules: map()
        }

  @spec check(map(), map(), ctx()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check(compose, devcontainer, ctx) do
    verdict(compose_findings(compose, ctx) ++ devcontainer_findings(devcontainer, ctx))
  end

  @doc """
  Checks the env files `compose` (the output of `docker compose config
  --no-interpolate`) names. With interpolation, Compose 2.x reads every
  env file and folds it into `environment:`, even with
  `--no-env-resolution`, so `check/3` never sees them. Without it, a path
  built from variables (which a repo's `.env` sets) can't be checked, so
  it's refused.
  """
  @spec check_env_files(map(), ctx()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check_env_files(compose, ctx) do
    verdict(
      for {service, %{} = svc} <- compose["services"] || %{},
          entry <- List.wrap(svc["env_file"]),
          path = env_file_path(entry),
          is_binary(path),
          finding <- uninterpolated_env_file(service, path, ctx),
          do: finding
    )
  end

  defp uninterpolated_env_file(service, path, ctx) do
    if String.contains?(path, "$"),
      do: [
        {:refuse,
         "service '#{service}' names env_file #{path}, which is built from variables; use a plain path"}
      ],
      else: host_file_finding("service '#{service}' reads env_file", path, ctx)
  end

  @doc """
  Checks the output of `devcontainer read-configuration
  --include-merged-configuration`: what each feature asks for, and the
  mounts after features are merged in.
  """
  @spec check_resolved(map(), ctx()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check_resolved(resolved, ctx) do
    merged = resolved["mergedConfiguration"] || %{}
    features = resolved_features(resolved)

    verdict(
      Enum.flat_map(features, &feature_findings(&1, ctx)) ++
        mount_findings(merged, ctx) ++
        unattributed_privileged(resolved, features, ctx) ++
        unattributed_caps(resolved, features, ctx) ++
        unattributed_security_opts(resolved, features, ctx)
    )
  end

  defp resolved_features(resolved) do
    for set <- get_in(resolved, ["featuresConfiguration", "featureSets"]) || [],
        feature <- set["features"] || [] do
      {get_in(set, ["sourceInformation", "userFeatureId"]) || feature["id"], feature}
    end
  end

  defp feature_findings({id, feature}, ctx) do
    caps = root_caps(feature["capAdd"])

    [
      feature["privileged"] == true && rule(ctx, :privileged, privileged_feature(id)),
      caps != [] &&
        rule(
          ctx,
          :privileged,
          "feature #{id} adds #{Enum.join(caps, ", ")}, which is root on the box"
        )
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(security_opt_findings("feature #{id}", feature["securityOpt"], ctx))
  end

  # Privileged in the merged config that no feature or devcontainer.json
  # owns up to. Refused all the same.
  defp unattributed_privileged(resolved, features, ctx) do
    attributed? =
      Enum.any?(features, fn {_, f} -> f["privileged"] == true end) or
        get_in(resolved, ["configuration", "privileged"]) == true

    if get_in(resolved, ["mergedConfiguration", "privileged"]) == true and not attributed?,
      do: [rule(ctx, :privileged, "the devcontainer runs privileged, which is root on the box")],
      else: []
  end

  # The CLI writes the merged config's capAdd and securityOpt into its own
  # compose override, wherever they came from (an image's
  # devcontainer.metadata label, say). Whatever no feature or the repo's
  # devcontainer.json declares is checked here.
  defp unattributed_caps(resolved, features, ctx) do
    declared =
      features
      |> Enum.flat_map(fn {_, f} -> root_caps(f["capAdd"]) end)
      |> Kernel.++(root_caps(get_in(resolved, ["configuration", "capAdd"])))
      |> MapSet.new(&cap_name/1)

    merged = root_caps(get_in(resolved, ["mergedConfiguration", "capAdd"]))

    case Enum.reject(merged, &(cap_name(&1) in declared)) do
      [] ->
        []

      caps ->
        [
          rule(
            ctx,
            :privileged,
            "the devcontainer adds #{Enum.join(caps, ", ")}, which is root on the box"
          )
        ]
    end
  end

  defp unattributed_security_opts(resolved, features, ctx) do
    declared =
      Enum.flat_map(features, fn {_, f} -> List.wrap(f["securityOpt"]) end) ++
        List.wrap(get_in(resolved, ["configuration", "securityOpt"]))

    opts = List.wrap(get_in(resolved, ["mergedConfiguration", "securityOpt"])) -- declared
    security_opt_findings("the devcontainer", opts, ctx)
  end

  defp verdict(findings) do
    refused = for {:refuse, msg} <- findings, do: msg
    warned = for {:warn, msg} <- findings, do: msg

    case refused do
      [] -> {:ok, Enum.uniq(warned)}
      refused -> {:error, Enum.uniq(refused)}
    end
  end

  # -- compose ---------------------------------------------------------------

  defp compose_findings(compose, ctx) do
    all = Map.get(compose, "services") || %{}
    ctx = Map.put(ctx, :services, Map.keys(all))

    services =
      all
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.flat_map(fn {name, svc} -> service_findings(name, svc || %{}, ctx) end)

    top_level =
      for kind <- ["secrets", "configs"],
          {key, spec} <- Map.get(compose, kind) || %{},
          is_map(spec),
          file = spec["file"],
          is_binary(file),
          finding <- host_file_finding("#{kind} '#{key}' reads", file, ctx) do
        finding
      end

    services ++ top_level ++ named_volume_findings(compose, ctx)
  end

  defp service_findings(name, svc, ctx) do
    Enum.flat_map(svc["volumes"] || [], &volume_finding(name, &1, ctx)) ++
      env_file_findings(name, svc, ctx) ++
      build_findings(name, svc, ctx) ++
      device_findings(name, svc, ctx) ++
      privilege_findings(name, svc, ctx) ++
      namespace_findings(name, svc, ctx) ++
      volumes_from_findings(name, svc, ctx) ++
      security_opt_findings("service '#{name}'", svc["security_opt"], ctx)
  end

  defp volume_finding(service, %{"type" => "bind", "source" => source} = vol, ctx) do
    bind_finding("service '#{service}'", source, vol["target"], vol["read_only"] == true, ctx)
  end

  defp volume_finding(service, vol, ctx) when is_binary(vol) do
    case String.split(vol, ":") do
      [source, target | rest] when binary_part(source, 0, 1) == "/" ->
        bind_finding("service '#{service}'", source, target, "ro" in rest, ctx)

      _ ->
        []
    end
  end

  defp volume_finding(_service, _vol, _ctx), do: []

  # Top-level volumes. A local volume with a device in its driver_opts is a
  # mount of that device: a host directory (o=bind) or a block device.
  defp named_volume_findings(compose, ctx) do
    for {key, spec} <- Map.get(compose, "volumes") || %{},
        is_map(spec),
        finding <- named_volume_finding(key, spec, compose["name"], ctx) do
      finding
    end
  end

  defp named_volume_finding(key, spec, project, ctx) do
    opts = spec["driver_opts"]

    cond do
      spec["driver"] in [nil, "local"] and is_map(opts) and is_binary(opts["device"]) ->
        driver_opts_finding(key, opts, ctx)

      # Another project's volume: another environment's database or
      # Tailscale identity, say.
      is_binary(project) and is_binary(spec["name"]) and
          not String.starts_with?(spec["name"], project <> "_") ->
        [
          rule(
            ctx,
            :host_bind,
            "volume '#{key}' is the Docker volume #{spec["name"]}, which belongs outside this environment"
          )
        ]

      true ->
        []
    end
  end

  defp driver_opts_finding(key, opts, ctx) do
    device = opts["device"]
    o = String.split(opts["o"] || "", ",")

    cond do
      opts["type"] in ["none", "bind"] or "bind" in o or "rbind" in o ->
        bind_finding("volume '#{key}'", device, nil, "ro" in o, ctx)

      String.starts_with?(device, "/") ->
        [rule(ctx, :devices, "volume '#{key}' mounts host device #{device}")]

      # tmpfs, or a network share (nfs, cifs).
      true ->
        []
    end
  end

  defp bind_finding(owner, source, target, read_only, ctx) do
    source = normalize(source)
    secrets = normalize(ctx.secrets_dir)

    cond do
      source == secrets and target == "/run/foreman" and read_only ->
        []

      source == secrets ->
        [
          {:refuse,
           "#{owner} mounts this environment's secrets somewhere other than /run/foreman (read-only)"}
        ]

      true ->
        case locate(source, ctx) do
          :workspace -> []
          {:host, real} -> host_bind_finding(owner, describe(source, real), real, ctx)
        end
    end
  end

  defp host_bind_finding(owner, shown, real, ctx) do
    cond do
      protected?(real, ctx) ->
        [{:refuse, "#{owner} mounts #{shown}, which exposes a protected path on the box"}]

      Enum.any?(@docker_sockets, &SafeFS.inside?(&1, real)) ->
        [
          rule(
            ctx,
            :docker_socket,
            "#{owner} mounts #{shown}, which exposes the Docker socket: root on the box"
          )
        ]

      true ->
        [rule(ctx, :host_bind, "#{owner} bind-mounts #{shown} from outside the workspace")]
    end
  end

  # A host file that compose or the build reads.
  defp host_file_finding(what, path, ctx) do
    path = normalize(path)

    case locate(path, ctx) do
      :workspace ->
        []

      {:host, real} ->
        if protected?(real, ctx),
          do: [{:refuse, "#{what} #{describe(path, real)}, a protected path on the box"}],
          else: [
            rule(ctx, :host_file, "#{what} #{describe(path, real)} from outside the workspace")
          ]
    end
  end

  defp describe(path, path), do: path
  defp describe(path, real), do: "#{path} (a link to #{real})"

  defp env_file_findings(service, svc, ctx) do
    for entry <- List.wrap(svc["env_file"]),
        path = env_file_path(entry),
        is_binary(path),
        finding <- host_file_finding("service '#{service}' reads env_file", path, ctx) do
      finding
    end
  end

  defp env_file_path(%{"path" => path}), do: path
  defp env_file_path(path) when is_binary(path), do: path
  defp env_file_path(_), do: nil

  defp build_findings(service, %{"build" => %{} = build}, ctx) do
    context = build["context"]
    local? = is_binary(context) and String.starts_with?(context, "/")

    contexts =
      [context | Map.values(build["additional_contexts"] || %{})]
      |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "/")))

    files = build_files(build, if(local?, do: context))

    context_findings =
      for path <- contexts,
          finding <- host_file_finding("service '#{service}' reads its build context", path, ctx) do
        finding
      end

    file_findings =
      for {what, path} <- files,
          finding <- host_file_finding("service '#{service}' reads its #{what}", path, ctx) do
        finding
      end

    context_findings ++ file_findings
  end

  defp build_findings(_service, _svc, _ctx), do: []

  # A Dockerfile can sit outside its context, and ssh keys are read from
  # the host. Both are relative to a local context; with a remote one,
  # only absolute paths are on the box.
  defp build_files(build, local_context) do
    for {what, path} <- [
          {"Dockerfile", build["dockerfile"]} | Enum.map(List.wrap(build["ssh"]), &ssh_key/1)
        ],
        is_binary(path) and path != "",
        local_context != nil or String.starts_with?(path, "/") do
      {what, Path.expand(path, local_context || "/")}
    end
  end

  # `default` forwards the agent's ssh-agent, which children don't get;
  # `id=path` reads a key from the box.
  defp ssh_key(%{} = entry), do: {"ssh key", entry |> Map.values() |> List.first()}

  defp ssh_key(entry) when is_binary(entry) do
    case String.split(entry, "=", parts: 2) do
      [_id, path] -> {"ssh key", path}
      _ -> {"ssh key", nil}
    end
  end

  defp ssh_key(_), do: {"ssh key", nil}

  defp device_findings(service, svc, ctx) do
    devices =
      for device <- svc["devices"] || [],
          source = device_source(device),
          source not in @allowed_devices do
        rule(ctx, :devices, "service '#{service}' maps host device #{source}")
      end

    # With CAP_MKNOD, which is in Docker's default set, a cgroup rule is
    # enough to make and use any device node.
    cgroup_rules =
      for rule <- List.wrap(svc["device_cgroup_rules"]) do
        rule(ctx, :devices, "service '#{service}' opens host devices with #{inspect(rule)}")
      end

    devices ++ cgroup_rules
  end

  defp device_source(%{"source" => source}), do: source
  defp device_source(device) when is_binary(device), do: device |> String.split(":") |> hd()
  defp device_source(other), do: inspect(other)

  defp privilege_findings(service, svc, ctx) do
    caps = root_caps(svc["cap_add"])

    [
      svc["privileged"] == true &&
        rule(ctx, :privileged, "service '#{service}' runs privileged, which is root on the box"),
      caps != [] &&
        rule(
          ctx,
          :privileged,
          "service '#{service}' adds #{Enum.join(caps, ", ")}, which is root on the box"
        )
    ]
    |> Enum.filter(& &1)
  end

  # The host's namespaces, or another container's. Container names are
  # predictable (<slug>-<service>-1), so another container is likely
  # another environment.
  defp namespace_findings(service, svc, ctx) do
    for {key, label} <- @namespaces,
        value = svc[key],
        is_binary(value),
        finding <- namespace_finding(service, label, value, ctx) do
      finding
    end
  end

  defp namespace_finding(service, label, "host", ctx),
    do: [rule(ctx, :host_namespace, "service '#{service}' uses the host #{label}")]

  defp namespace_finding(service, label, "container:" <> name, ctx) do
    [
      rule(
        ctx,
        :host_namespace,
        "service '#{service}' joins the #{label} of container #{name}, outside this environment"
      )
    ]
  end

  defp namespace_finding(_service, _label, _value, _ctx), do: []

  defp volumes_from_findings(service, svc, ctx) do
    for entry <- List.wrap(svc["volumes_from"]),
        is_binary(entry),
        finding <- volumes_from_finding(service, entry, ctx) do
      finding
    end
  end

  defp volumes_from_finding(service, "container:" <> rest, ctx) do
    name = rest |> String.split(":") |> hd()

    [
      rule(
        ctx,
        :host_namespace,
        "service '#{service}' mounts the volumes of container #{name}, outside this environment"
      )
    ]
  end

  defp volumes_from_finding(service, entry, ctx) do
    name = entry |> String.split(":") |> hd()

    if name in ctx.services,
      do: [],
      else: [
        rule(
          ctx,
          :host_namespace,
          "service '#{service}' mounts the volumes of #{name}, which isn't a service in this project"
        )
      ]
  end

  # Anything that loosens a container's confinement (AppArmor, SELinux
  # labels, /proc and /sys masking, a custom seccomp profile) counts as
  # privileged. Turning seccomp off has a rule of its own, because common
  # features ask for it (for debuggers) and a box may accept that without
  # accepting privileged containers. no-new-privileges only tightens.
  defp security_opt_findings(owner, opts, ctx) do
    for opt <- List.wrap(opts),
        is_binary(opt),
        not String.starts_with?(opt, "no-new-privileges") do
      if seccomp_unconfined?(opt) do
        rule(
          ctx,
          :seccomp,
          "#{owner} sets security_opt #{opt}, which turns off seccomp filtering of system calls. " <>
            "Remove it from the repo's config or features (the official Go and Rust features " <>
            "set it, for debuggers), or allow it on this box with FOREMAN_POLICY=seccomp=allow"
        )
      else
        rule(ctx, :privileged, "#{owner} sets security_opt #{opt}, which weakens its confinement")
      end
    end
  end

  defp seccomp_unconfined?(opt),
    do: opt |> String.replace(":", "=", global: false) |> String.trim() == "seccomp=unconfined"

  # -- devcontainer.json -----------------------------------------------------

  # The repo's own devcontainer.json. docker-in-docker is caught by name
  # here so it fails fast; check_resolved/2 catches any feature by its
  # metadata.
  defp devcontainer_findings(config, ctx) do
    features =
      for {id, _opts} <- config["features"] || %{},
          String.contains?(id, "docker-in-docker") do
        rule(ctx, :privileged, privileged_feature(id))
      end

    privileged =
      if config["privileged"] == true,
        do: [
          rule(ctx, :privileged, "devcontainer.json sets privileged, which is root on the box")
        ],
        else: []

    caps =
      case root_caps(config["capAdd"]) do
        [] ->
          []

        caps ->
          [
            rule(
              ctx,
              :privileged,
              "devcontainer.json adds #{Enum.join(caps, ", ")}, which is root on the box"
            )
          ]
      end

    features ++
      mount_findings(config, ctx) ++
      privileged ++
      caps ++ security_opt_findings("devcontainer.json", config["securityOpt"], ctx)
  end

  defp mount_findings(config, ctx) do
    for mount <- List.wrap(config["mounts"]),
        {source, target, type, ro} = parse_mount(mount),
        type == "bind",
        is_binary(source),
        finding <- bind_finding("devcontainer.json", source, target, ro, ctx) do
      finding
    end
  end

  defp privileged_feature(id),
    do: "feature #{id} runs the devcontainer privileged, which is root on the box"

  defp root_caps(caps) when is_list(caps) do
    Enum.filter(caps, &(is_binary(&1) and cap_name(&1) in @root_caps))
  end

  defp root_caps(_), do: []

  defp cap_name(cap), do: cap |> String.upcase() |> String.replace_prefix("CAP_", "")

  defp parse_mount(%{} = m), do: {m["source"], m["target"], m["type"], m["readonly"] == true}

  defp parse_mount(m) when is_binary(m) do
    pairs =
      m
      |> String.split(",")
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> {String.trim(k), String.trim(v)}
          [k] -> {String.trim(k), "true"}
        end
      end)

    {pairs["source"] || pairs["src"], pairs["target"] || pairs["dst"] || pairs["destination"],
     pairs["type"], Map.has_key?(pairs, "readonly") or Map.has_key?(pairs, "ro")}
  end

  defp parse_mount(_), do: {nil, nil, nil, false}

  # -- paths -----------------------------------------------------------------

  defp rule(ctx, name, message), do: {Map.get(ctx.rules, name, :refuse), message}

  # Where a host path really is. Compose keeps a symlink's path as written
  # and the kernel follows it at mount time, and anything in the
  # environment can put a symlink in the workspace, so a path under the
  # workspace only counts as the workspace if it resolves inside it. A
  # path that doesn't exist yet is created by Docker where it's written.
  defp locate(path, ctx) do
    root = normalize(ctx.workspace_root)

    if SafeFS.inside?(path, root) do
      case SafeFS.resolve(root, Path.relative_to(path, root)) do
        {:ok, _} -> :workspace
        {:error, reason} when reason in [:enoent, :enotdir] -> :workspace
        {:error, _} -> {:host, real(path)}
      end
    else
      {:host, real(path)}
    end
  end

  defp real(path) do
    case SafeFS.real_path(path) do
      {:ok, real} -> normalize(real)
      {:error, _} -> path
    end
  end

  # A host path exposes a protected path when it contains it or sits
  # inside it, under the protected path's own name or its real one.
  defp protected?(source, ctx) do
    ctx.protected
    |> Enum.flat_map(&[normalize(&1), real(normalize(&1))])
    |> Enum.any?(fn protected ->
      SafeFS.inside?(source, protected) or SafeFS.inside?(protected, source)
    end)
  end

  defp normalize(path) do
    path = path |> Path.expand() |> resolve_known_links()
    if path == "/", do: path, else: String.trim_trailing(path, "/")
  end

  # /var/run is a symlink to /run on every distro the agent supports.
  defp resolve_known_links("/var/run"), do: "/run"
  defp resolve_known_links("/var/run/" <> rest), do: "/run/" <> rest
  defp resolve_known_links(path), do: path
end
