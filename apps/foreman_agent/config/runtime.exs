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

  # FOREMAN_POLICY="host_bind=warn,privileged=refuse"
  rules = ~w(host_bind host_file docker_socket devices privileged host_namespace)
  actions = ~w(refuse warn allow)

  policy =
    for pair <- list.("FOREMAN_POLICY", []), into: %{} do
      with [rule, action] <- String.split(pair, "=", parts: 2),
           true <- rule in rules and action in actions do
        {String.to_atom(rule), String.to_atom(action)}
      else
        _ -> raise "invalid FOREMAN_POLICY entry #{inspect(pair)}"
      end
    end

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
    devcontainer: System.get_env("FOREMAN_DEVCONTAINER_CLI", "devcontainer"),
    docker_socket: docker_socket,
    allowed_git_hosts: list.("FOREMAN_ALLOWED_GIT_HOSTS", ["github.com"]),
    insecure_git_hosts: list.("FOREMAN_INSECURE_GIT_HOSTS", []),
    policy_rules: policy,
    tun_device:
      (case System.get_env("FOREMAN_TUN_DEVICE", "auto") do
         "auto" -> :auto
         value -> value == "true"
       end),
    connect: System.get_env("FOREMAN_URL") not in [nil, ""]
end
