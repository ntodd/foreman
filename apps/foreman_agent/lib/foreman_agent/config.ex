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
            devcontainer: "devcontainer",
            docker: "docker",
            git: "git",
            docker_socket: "/var/run/docker.sock",
            allowed_git_hosts: ["github.com"],
            insecure_git_hosts: [],
            policy_rules: %{},
            tun_device: :auto,
            cleanup_image: "alpine:3.22",
            release_root: "/opt/foreman-agent",
            release_public_key: nil,
            feature_dir: nil,
            join_token: nil,
            connect: true

  @type t :: %__MODULE__{}

  @spec load() :: t()
  def load do
    env = Application.get_all_env(:foreman_agent)

    struct(__MODULE__, Keyword.take(env, Map.keys(%__MODULE__{}) -- [:__struct__]))
    |> Map.update!(:policy_rules, &Map.merge(Policy.default_rules(), &1))
    |> Map.put(:release_public_key, decode_key(env[:release_public_key] || @release_public_key))
    |> Map.update!(:feature_dir, &(&1 || default_feature_dir()))
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

  @doc "Paths no environment may ever bind-mount."
  def protected_paths(%__MODULE__{} = c),
    do: [c.data_dir, c.envs_root, c.secrets_root, c.release_root]

  def tun_device?(%__MODULE__{tun_device: :auto}) do
    match?({:ok, %File.Stat{type: :device}}, File.stat("/dev/net/tun"))
  end

  def tun_device?(%__MODULE__{tun_device: value}), do: value == true

  defp default_feature_dir do
    priv = Application.app_dir(:foreman_agent, "priv/feature")
    if File.dir?(priv), do: priv, else: @repo_feature
  end

  defp decode_key(nil), do: nil
  defp decode_key(key) when byte_size(key) == 32, do: key
  defp decode_key(key) when is_binary(key), do: Base.decode64!(key)
end
