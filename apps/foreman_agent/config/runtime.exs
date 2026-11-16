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

  config :foreman_agent,
    url: System.get_env("FOREMAN_URL"),
    join_token: System.get_env("FOREMAN_JOIN_TOKEN"),
    data_dir: System.get_env("FOREMAN_AGENT_DATA_DIR", "/var/lib/foreman-agent"),
    envs_root: System.get_env("FOREMAN_ENVS_ROOT", "/srv/foreman/envs"),
    secrets_root: System.get_env("FOREMAN_SECRETS_ROOT", "/run/foreman/envs"),
    release_root: System.get_env("FOREMAN_RELEASE_ROOT", "/opt/foreman-agent"),
    # The release carries both; these override it (ForemanAgent.Config.tools/2).
    devcontainer: System.get_env("FOREMAN_DEVCONTAINER_CLI"),
    node: System.get_env("FOREMAN_NODE"),
    docker_socket: docker_socket,
    allowed_git_hosts: list.("FOREMAN_ALLOWED_GIT_HOSTS", ["github.com"]),
    insecure_git_hosts: list.("FOREMAN_INSECURE_GIT_HOSTS", []),
    policy_rules: policy,
    connect: System.get_env("FOREMAN_URL") not in [nil, ""]
end
