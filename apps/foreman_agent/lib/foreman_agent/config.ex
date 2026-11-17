defmodule ForemanAgent.Config do
  @moduledoc """
  Agent configuration, read once at boot from the application environment
  (which `config/runtime.exs` fills from `FOREMAN_*` variables).
  """

  @repo_feature Path.expand("../../../../features/src/foreman", __DIR__)
  @release_public_key Application.compile_env(:foreman_agent, :release_public_key)
  @guest_url Application.compile_env(:foreman_agent, :guest_url)
  @guest_sha256 Application.compile_env(:foreman_agent, :guest_sha256)

  # Read once and cached (get/0), so the size of the map doesn't matter.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
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
            # :host on a box; :guest in an environment's VM, where the
            # agent serves the box's agent on guest_socket (see
            # ForemanAgent.Guest).
            mode: :host,
            guest_socket: "/run/foreman-guest/agent.sock",
            # Environment VMs, on the box (see ForemanAgent.VM).
            vm_root: "/srv/foreman/vms",
            guest_root: "/srv/foreman/guest",
            agent_disks: "/srv/foreman/agent-disks",
            prebuilds_root: "/srv/foreman/prebuilds",
            vmctl_socket: "/run/foreman-vmctl.sock",
            # The guest system image: release builds carry its URL and
            # SHA-256 (FOREMAN_GUEST_URL, FOREMAN_GUEST_SHA256 at build
            # time); the same variables at run time override them.
            guest_url: nil,
            guest_sha256: nil,
            # A VM's size when the environment has no limits of its own.
            vm_cpus: 4,
            vm_memory_mb: 8192,
            vm_disk_gb: 64,
            # How long a booted VM's guest agent gets to answer.
            vm_boot_timeout: 120_000,
            # How long the guest gets for its part of a stop (its
            # containers') before the VM is shut down anyway, and for a
            # Docker prune (each prune in the guest has half an hour).
            vm_relay_stop_timeout: 300_000,
            vm_relay_gc_timeout: 2_400_000,
            # A prebuild's build, past which the box gives it up and gives
            # its VM back (the control plane gives up at five hours).
            prebuild_timeout: 16_200_000,
            machine: ForemanAgent.VM.Machine.Cloud,
            tailscale_join_wait: :timer.seconds(30)

  @type t :: %__MODULE__{}

  @spec load() :: t()
  def load do
    env = Application.get_all_env(:foreman_agent)

    struct(__MODULE__, Keyword.take(env, Map.keys(%__MODULE__{}) -- [:__struct__]))
    |> Map.put(:release_public_key, decode_key(env[:release_public_key] || @release_public_key))
    |> Map.put(:guest_url, present(env[:guest_url_override]) || present(@guest_url))
    |> Map.put(:guest_sha256, present(env[:guest_sha256_override]) || present(@guest_sha256))
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
      case override(overrides[:devcontainer]) do
        @legacy_cli when is_binary(bundled_cli) -> bundled_cli
        nil -> bundled_cli || "devcontainer"
        path -> path
      end

    node = override(overrides[:node]) || bundled(dir, "node/bin/node") || "node"
    %{devcontainer: cli, node: node}
  end

  defp override(path) when is_binary(path) and path != "", do: path
  defp override(_path), do: nil

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
    do: [c.data_dir, c.envs_root, c.secrets_root, c.release_root, c.vm_root]

  defp default_tools_dir, do: Application.app_dir(:foreman_agent, "priv/tools")

  defp default_firewall_rules,
    do: Application.app_dir(:foreman_agent, "priv/firewall/foreman.nft")

  defp default_feature_dir do
    priv = Application.app_dir(:foreman_agent, "priv/feature")
    if File.dir?(priv), do: priv, else: @repo_feature
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp decode_key(nil), do: nil
  defp decode_key(key) when byte_size(key) == 32, do: key
  defp decode_key(key) when is_binary(key), do: Base.decode64!(key)
end
