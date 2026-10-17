import Config

# Agent settings come from FOREMAN_* environment variables (set by the
# systemd unit or the box container). Tests configure the agent directly.
if config_env() != :test do
  list = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  # Every rule refuses by default. A box opens one up as an exception, for
  # example FOREMAN_POLICY="seccomp=allow", and the control plane shows
  # that box with a red alert. The rules are ForemanProtocol.Policy's.
  policy = ForemanAgent.Config.parse_policy(list.("FOREMAN_POLICY", []))

  docker_socket =
    case System.get_env("DOCKER_HOST") do
      "unix://" <> path -> path
      _ -> System.get_env("FOREMAN_DOCKER_SOCKET", "/var/run/docker.sock")
    end

  int = fn name, default ->
    case System.get_env(name) do
      value when value in [nil, ""] -> default
      value -> String.to_integer(value)
    end
  end

  config :foreman_agent,
    # FOREMAN_ISOLATION=vm runs each environment in its own Incus VM.
    isolation: ForemanAgent.Config.parse_isolation(System.get_env("FOREMAN_ISOLATION")),
    incus: System.get_env("FOREMAN_INCUS", "incus"),
    vm_image: System.get_env("FOREMAN_VM_IMAGE", "foreman-env"),
    vm_profiles: list.("FOREMAN_VM_PROFILES", []),
    vm_cpus: int.("FOREMAN_VM_CPUS", nil),
    vm_memory_mb: int.("FOREMAN_VM_MEMORY_MB", 8192),
    vm_disk_gb: int.("FOREMAN_VM_DISK_GB", 64),
    vm_policy_rules: ForemanAgent.Config.parse_policy(list.("FOREMAN_VM_POLICY", [])),
    vm_registry_auth: System.get_env("FOREMAN_VM_REGISTRY_AUTH") == "allow",
    url: System.get_env("FOREMAN_URL"),
    join_token: System.get_env("FOREMAN_JOIN_TOKEN"),
    data_dir: System.get_env("FOREMAN_AGENT_DATA_DIR", "/var/lib/foreman-agent"),
    envs_root: System.get_env("FOREMAN_ENVS_ROOT", "/srv/foreman/envs"),
    secrets_root: System.get_env("FOREMAN_SECRETS_ROOT", "/run/foreman/envs"),
    release_root: System.get_env("FOREMAN_RELEASE_ROOT", "/opt/foreman-agent"),
    devcontainer: System.get_env("FOREMAN_DEVCONTAINER_CLI", "devcontainer"),
    docker_socket: docker_socket,
    allowed_git_hosts: list.("FOREMAN_ALLOWED_GIT_HOSTS", ["github.com"]),
    insecure_git_hosts: list.("FOREMAN_INSECURE_GIT_HOSTS", []),
    policy_rules: policy,
    connect: System.get_env("FOREMAN_URL") not in [nil, ""]
end
