defmodule ForemanAgent.Config do
  @moduledoc """
  Agent configuration, read once at boot from the application environment
  (which `config/runtime.exs` fills from `FOREMAN_*` variables).
  """

  alias ForemanAgent.Env.Policy

  @repo_feature Path.expand("../../../../features/src/foreman", __DIR__)
  @release_public_key Application.compile_env(:foreman_agent, :release_public_key)

  defstruct url: nil,
            data_dir: "/var/lib/foreman-agent",
            envs_root: "/srv/foreman/envs",
            secrets_root: "/run/foreman/envs",
            # load/0 resolves these with tools/2.
            devcontainer: "devcontainer",
            node: "node",
            docker: "docker",
            git: "git",
            docker_socket: "/var/run/docker.sock",
            proc: "/proc",
            allowed_git_hosts: ["github.com"],
            insecure_git_hosts: [],
            policy_rules: %{},
            cleanup_image: "alpine:3.22",
            release_root: "/opt/foreman-agent",
            release_public_key: nil,
            feature_dir: nil,
            firewall_rules: nil,
            firewall_marker: "/run/foreman-firewall/loaded",
            firewall_info: "/etc/foreman-agent/firewall.info",
            reboot_required: "/run/reboot-required",
            livepatch_dir: "/sys/kernel/livepatch",
            # The root unit the install script sets up to reboot the box
            # (box.restart), and the file it watches.
            restart_unit: "/etc/systemd/system/foreman-restart.path",
            restart_request: "/run/foreman/restart",
            boot_id: "/proc/sys/kernel/random/boot_id",
            join_token: nil,
            connect: true,
            tailscale_join_wait: :timer.seconds(30)

  @type t :: %__MODULE__{}

  @spec load() :: t()
  def load do
    env = Application.get_all_env(:foreman_agent)

    struct(__MODULE__, Keyword.take(env, Map.keys(%__MODULE__{}) -- [:__struct__]))
    |> Map.update!(:policy_rules, &Map.merge(Policy.default_rules(), &1))
    |> Map.put(:release_public_key, decode_key(env[:release_public_key] || @release_public_key))
    |> Map.update!(:feature_dir, &(&1 || default_feature_dir()))
    |> Map.update!(:firewall_rules, &(&1 || default_firewall_rules()))
    |> Map.merge(tools(default_tools_dir(), Map.new([:devcontainer, :node], &{&1, env[&1]})))
  end

  @doc "The loaded config. Loaded on first use and cached."
  @spec get() :: t()
  def get do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        config = load()
        :persistent_term.put(__MODULE__, config)
        config

      config ->
        config
    end
  end

  def put(%__MODULE__{} = config), do: :persistent_term.put(__MODULE__, config)

  @doc "The box's policy as it's reported to the control plane on join."
  def policy_report(%__MODULE__{policy_rules: rules}),
    do: Map.new(rules, fn {rule, action} -> {to_string(rule), to_string(action)} end)

  @doc """
  Parses `FOREMAN_POLICY` entries (`rule=action`) into policy rules.
  Raises on a rule or action the protocol doesn't know, so a typo stops
  the agent rather than leaving a rule at its default unnoticed.
  """
  @spec parse_policy([String.t()]) :: %{atom() => atom()}
  def parse_policy(pairs) do
    rules = ForemanProtocol.Policy.rules()
    actions = ForemanProtocol.Policy.actions()

    Map.new(pairs, fn pair ->
      with [rule, action] <- String.split(pair, "=", parts: 2),
           true <- rule in rules and action in actions do
        {String.to_atom(rule), String.to_atom(action)}
      else
        _ ->
          raise ArgumentError,
                "invalid FOREMAN_POLICY entry #{inspect(pair)}; rules: " <>
                  "#{Enum.join(rules, ", ")}; actions: #{Enum.join(actions, ", ")}"
      end
    end)
  end

  # Where install scripts before the bundled CLI put the one they installed
  # with npm, and what they wrote to agent.env: a self-update keeps that
  # file, and the release's own CLI replaces it.
  @legacy_cli "/opt/foreman-agent/node/node_modules/.bin/devcontainer"

  @doc """
  The devcontainer CLI and Node the agent runs. A release carries both in
  `dir` (priv/tools: `bin/devcontainer` and `node/bin/node`), so a box
  needs no Node of its own. An override (`FOREMAN_DEVCONTAINER_CLI`,
  `FOREMAN_NODE`) wins, except the path older install scripts wrote,
  which gives way to the release's. Without them, both come from PATH.
  """
  @spec tools(Path.t() | nil, %{optional(:devcontainer | :node) => String.t() | nil}) ::
          %{devcontainer: String.t(), node: String.t()}
  def tools(dir, overrides) do
    bundled_cli = bundled(dir, "bin/devcontainer")

    cli =
      case overrides[:devcontainer] do
        @legacy_cli when is_binary(bundled_cli) -> bundled_cli
        path when is_binary(path) and path != "" -> path
        _ -> bundled_cli || "devcontainer"
      end

    node =
      case overrides[:node] do
        path when is_binary(path) and path != "" -> path
        _ -> bundled(dir, "node/bin/node") || "node"
      end

    %{devcontainer: cli, node: node}
  end

  defp bundled(nil, _rel), do: nil

  defp bundled(root, rel) do
    path = Path.join(root, rel)
    if File.regular?(path), do: path
  end

  @doc "The version of the Foreman feature this agent installs, or nil if it can't be read."
  @spec feature_version(t()) :: String.t() | nil
  def feature_version(%__MODULE__{feature_dir: dir}) do
    with {:ok, content} <- File.read(Path.join(dir, "devcontainer-feature.json")),
         {:ok, %{"version" => version}} when is_binary(version) <- JSON.decode(content),
         {:ok, _} <- Version.parse(version) do
      version
    else
      _ -> nil
    end
  end

  @doc "Paths no environment may ever bind-mount."
  def protected_paths(%__MODULE__{} = c),
    do: [c.data_dir, c.envs_root, c.secrets_root, c.release_root]

  defp default_tools_dir, do: Application.app_dir(:foreman_agent, "priv/tools")

  defp default_firewall_rules,
    do: Application.app_dir(:foreman_agent, "priv/firewall/foreman.nft")

  defp default_feature_dir do
    priv = Application.app_dir(:foreman_agent, "priv/feature")
    if File.dir?(priv), do: priv, else: @repo_feature
  end

  defp decode_key(nil), do: nil
  defp decode_key(key) when byte_size(key) == 32, do: key
  defp decode_key(key) when is_binary(key), do: Base.decode64!(key)
end
