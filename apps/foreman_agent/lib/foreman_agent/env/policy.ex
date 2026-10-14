defmodule ForemanAgent.Env.Policy do
  @moduledoc """
  Checks an environment's merged compose config (and its devcontainer.json)
  before the agent starts it.

  A repo's compose files can bind any host path into a container, read any
  host file into a container's environment, or share the host's network.
  Repos are trusted to the level of the box they run on, but a compose file
  in the workspace can be rewritten by anything running inside the
  environment, so the agent checks it on every start, not just the first.

  Some things are refused no matter what the box allows: binds that expose
  the agent's own state, other environments, or secrets directories.
  Everything else is a rule with an action per box: `:refuse`, `:warn` or
  `:allow`. Every rule refuses unless the box opts out (see
  `ForemanProtocol.Policy`).

  Features can ask for privileges in their own metadata, so `check/3`
  covers the repo's files and `check_resolved/2` covers what the
  devcontainer CLI resolves, features included.
  """

  @default_rules Map.new(ForemanProtocol.Policy.defaults(), fn {rule, action} ->
                   {String.to_atom(rule), String.to_atom(action)}
                 end)

  # Capabilities that are root on the box from inside a container.
  @root_caps ~w(ALL SYS_ADMIN SYS_MODULE SYS_RAWIO DAC_READ_SEARCH BPF PERFMON MAC_ADMIN)

  @allowed_devices ["/dev/net/tun"]
  @docker_sockets ["/run/docker.sock", "/var/run/docker.sock"]

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
        mount_findings(merged, ctx) ++ unattributed_privileged(resolved, features, ctx)
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

  defp verdict(findings) do
    refused = for {:refuse, msg} <- findings, do: msg
    warned = for {:warn, msg} <- findings, do: msg

    case refused do
      [] -> {:ok, Enum.uniq(warned)}
      refused -> {:error, Enum.uniq(refused)}
    end
  end

  defp compose_findings(compose, ctx) do
    services =
      compose
      |> Map.get("services", %{})
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.flat_map(fn {name, svc} -> service_findings(name, svc || %{}, ctx) end)

    top_level =
      for kind <- ["secrets", "configs"],
          {key, spec} <- Map.get(compose, kind) || %{},
          is_map(spec),
          file = spec["file"],
          is_binary(file),
          not in_workspace?(file, ctx) do
        rule(ctx, :host_file, "#{kind} '#{key}' reads #{file} from outside the workspace")
      end

    services ++ top_level
  end

  defp service_findings(name, svc, ctx) do
    Enum.flat_map(svc["volumes"] || [], &volume_finding(name, &1, ctx)) ++
      env_file_findings(name, svc, ctx) ++
      build_findings(name, svc, ctx) ++
      device_findings(name, svc, ctx) ++
      privilege_findings(name, svc, ctx)
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

      in_workspace?(source, ctx) ->
        []

      protected?(source, ctx) ->
        [{:refuse, "#{owner} mounts #{source}, which exposes a protected path on the box"}]

      source in @docker_sockets ->
        [
          rule(
            ctx,
            :docker_socket,
            "#{owner} mounts the Docker socket (#{source}), which is root on the box"
          )
        ]

      true ->
        [rule(ctx, :host_bind, "#{owner} bind-mounts #{source} from outside the workspace")]
    end
  end

  defp env_file_findings(service, svc, ctx) do
    for entry <- List.wrap(svc["env_file"]),
        path = env_file_path(entry),
        is_binary(path),
        not in_workspace?(path, ctx) do
      rule(
        ctx,
        :host_file,
        "service '#{service}' reads env_file #{path} from outside the workspace"
      )
    end
  end

  defp env_file_path(%{"path" => path}), do: path
  defp env_file_path(path) when is_binary(path), do: path
  defp env_file_path(_), do: nil

  defp build_findings(service, %{"build" => %{} = build}, ctx) do
    contexts =
      [build["context"] | Map.values(build["additional_contexts"] || %{})]
      |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "/")))

    for path <- contexts, not in_workspace?(path, ctx) do
      rule(
        ctx,
        :host_file,
        "service '#{service}' uses #{path} as a build context, outside the workspace"
      )
    end
  end

  defp build_findings(_service, _svc, _ctx), do: []

  defp device_findings(service, svc, ctx) do
    for device <- svc["devices"] || [],
        source = device_source(device),
        source not in @allowed_devices do
      rule(ctx, :devices, "service '#{service}' maps host device #{source}")
    end
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
        ),
      svc["network_mode"] == "host" &&
        rule(ctx, :host_namespace, "service '#{service}' uses the host network"),
      svc["pid"] == "host" &&
        rule(ctx, :host_namespace, "service '#{service}' uses the host PID namespace"),
      svc["ipc"] == "host" &&
        rule(ctx, :host_namespace, "service '#{service}' uses the host IPC namespace")
    ]
    |> Enum.filter(& &1)
  end

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

    features ++ mount_findings(config, ctx) ++ privileged ++ caps
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
    Enum.filter(caps, fn cap ->
      is_binary(cap) and
        (cap |> String.upcase() |> String.replace_prefix("CAP_", "")) in @root_caps
    end)
  end

  defp root_caps(_), do: []

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

  defp rule(ctx, name, message), do: {Map.get(ctx.rules, name, :refuse), message}

  defp in_workspace?(path, ctx),
    do: ForemanAgent.SafeFS.inside?(normalize(path), normalize(ctx.workspace_root))

  # A bind source exposes a protected path when it contains it or sits inside it.
  defp protected?(source, ctx) do
    Enum.any?(ctx.protected, fn protected ->
      protected = normalize(protected)

      ForemanAgent.SafeFS.inside?(source, protected) or
        ForemanAgent.SafeFS.inside?(protected, source)
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
