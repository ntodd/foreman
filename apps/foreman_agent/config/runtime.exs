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

  int = fn name, default ->
    case System.get_env(name) do
      value when value in [nil, ""] -> default
      value -> String.to_integer(value)
    end
  end

  docker_socket =
    case System.get_env("DOCKER_HOST") do
      "unix://" <> path -> path
      _ -> System.get_env("FOREMAN_DOCKER_SOCKET", "/var/run/docker.sock")
    end

  # In an environment's VM the agent takes its commands from the box's
  # agent, not the control plane (ForemanAgent.Guest).
  mode =
    case System.get_env("FOREMAN_AGENT_MODE", "host") do
      "host" ->
        :host

      "guest" ->
        :guest

      other ->
        raise ArgumentError, "FOREMAN_AGENT_MODE must be host or guest, not #{inspect(other)}"
    end

  config :foreman_agent,
    mode: mode,
    url: System.get_env("FOREMAN_URL"),
    join_token: System.get_env("FOREMAN_JOIN_TOKEN"),
    data_dir: System.get_env("FOREMAN_AGENT_DATA_DIR", "/var/lib/foreman-agent"),
    envs_root: System.get_env("FOREMAN_ENVS_ROOT", "/srv/foreman/envs"),
    secrets_root: System.get_env("FOREMAN_SECRETS_ROOT", "/run/foreman/envs"),
    release_root: System.get_env("FOREMAN_RELEASE_ROOT", "/opt/foreman-agent"),
    docker_socket: docker_socket,
    allowed_git_hosts: list.("FOREMAN_ALLOWED_GIT_HOSTS", ["github.com"]),
    insecure_git_hosts: list.("FOREMAN_INSECURE_GIT_HOSTS", []),
    # Not guest_url and guest_sha256: those are read at compile time.
    guest_url_override: System.get_env("FOREMAN_GUEST_URL"),
    guest_sha256_override: System.get_env("FOREMAN_GUEST_SHA256"),
    vm_cpus: int.("FOREMAN_VM_CPUS", 4),
    vm_memory_mb: int.("FOREMAN_VM_MEMORY_MB", 8192),
    vm_disk_gb: int.("FOREMAN_VM_DISK_GB", 64),
    vm_reclaim_below: int.("FOREMAN_VM_RECLAIM_BELOW", 20),
    vm_reclaim_keep_mb: int.("FOREMAN_VM_RECLAIM_KEEP_MB", 2048),
    vm_reclaim_idle_minutes: int.("FOREMAN_VM_RECLAIM_IDLE_MINUTES", nil),
    connect: mode == :host and System.get_env("FOREMAN_URL") not in [nil, ""]
end
