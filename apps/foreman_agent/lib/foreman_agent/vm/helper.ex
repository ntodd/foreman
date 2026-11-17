defmodule ForemanAgent.VM.Helper do
  @moduledoc """
  The agent's side of `foreman-vmctl`, the root helper install.sh sets up
  for environment VMs (`priv/vm/vmctl`): the agent runs unprivileged, and
  a VM needs a tap, an address and a systemd unit of its own, which take
  root.

  The helper listens on a unix socket only the agent's group can reach,
  takes one request line per connection and answers one line. Its
  vocabulary is fixed, and it takes ids, sizes and versions, never paths
  or command lines: it builds Cloud Hypervisor's command line itself.
  """

  alias ForemanAgent.Config

  # The helper protocol this agent speaks. A helper older than this was
  # installed by an older install.sh; re-running it installs this one.
  # Version 2 refuses VMs on a kernel without Landlock instead of running
  # them unconfined, keeps VMs from its socket, and says which tap a VM
  # has, which a resume checks its snapshot against.
  @version 2
  @timeout 60_000

  def version, do: @version

  @doc """
  Whether the installed helper can run this agent's VMs: new enough, on a
  kernel that can confine them (Landlock). The reason when it can't.
  """
  @spec ready(Config.t()) :: :ok | {:error, String.t()}
  def ready(config) do
    case installed_version(config) do
      {:ok, version} when version >= @version -> landlock(config)
      _ -> {:error, "the VM helper is missing or too old; re-run the install script"}
    end
  end

  defp landlock(config) do
    with {:ok, _} <- request(config, ["landlock"]), do: :ok
  end

  @doc "The installed helper's version."
  @spec installed_version(Config.t()) :: {:ok, integer()} | {:error, String.t()}
  def installed_version(config) do
    with {:ok, [version | _]} <- request(config, ["version"]),
         {int, ""} <- Integer.parse(version) do
      {:ok, int}
    else
      {:error, message} -> {:error, message}
      _ -> {:error, "the VM helper gave a version this agent can't read"}
    end
  end

  @doc """
  The tap the helper gave an environment's VM, which a VM restored from
  its snapshot has to come back on.
  """
  @spec tap(Config.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def tap(config, env_id) do
    case request(config, ["tap", env_id]) do
      {:ok, ["fm-vm" <> _ = tap]} ->
        {:ok, tap}

      {:ok, other} ->
        {:error, "the VM helper named a tap this agent can't read: #{inspect(other)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Boots an environment's VM from its disks."
  def start(config, env_id, spec) do
    request(config, [
      "start",
      env_id,
      Integer.to_string(spec.cpus),
      Integer.to_string(spec.memory_mb),
      spec.guest,
      spec.agent_version
    ])
  end

  @doc "Starts an environment's VM from its snapshot."
  def restore(config, env_id, spec) do
    request(config, [
      "restore",
      env_id,
      Integer.to_string(spec.cpus),
      Integer.to_string(spec.memory_mb)
    ])
  end

  @doc "Stops an environment's VM at once (its unit)."
  def stop(config, env_id), do: request(config, ["stop", env_id])

  @doc "Stops an environment's VM and gives back its tap and address."
  def release(config, env_id), do: request(config, ["release", env_id])

  @doc false
  @spec request(Config.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def request(config, words) do
    opts = [:binary, packet: :line, active: false, packet_size: 4096]

    with {:ok, socket} <- connect(config.vmctl_socket, opts) do
      try do
        with :ok <- :gen_tcp.send(socket, Enum.join(words, " ") <> "\n"),
             {:ok, line} <- :gen_tcp.recv(socket, 0, @timeout) do
          answer(String.trim_trailing(line))
        else
          {:error, reason} -> {:error, "the VM helper didn't answer (#{inspect(reason)})"}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp connect(path, opts) do
    case :gen_tcp.connect({:local, path}, 0, opts, 5_000) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        {:error,
         "couldn't reach the VM helper at #{path} (#{inspect(reason)}); " <>
           "re-run the install script on this box"}
    end
  end

  defp answer("ok" <> rest), do: {:ok, String.split(rest)}
  defp answer("error " <> message), do: {:error, message}
  defp answer(other), do: {:error, "the VM helper said #{inspect(String.slice(other, 0, 200))}"}
end
