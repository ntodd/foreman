defmodule ForemanAgent.VM.Machine do
  @moduledoc """
  Starting, stopping and watching environment VMs. The box's
  implementation is `ForemanAgent.VM.Machine.Cloud` (Cloud Hypervisor,
  through the root helper); tests use one that runs a guest agent in the
  test's own VM.

  `spec` is `%{cpus, memory_mb, guest, agent_version}`: the size, the
  guest image's SHA-256 and the agent release on the agent disk.
  """

  alias ForemanAgent.Config

  @type spec :: %{
          cpus: pos_integer(),
          memory_mb: pos_integer(),
          guest: String.t(),
          agent_version: String.t()
        }

  @doc "Boots the VM from its disks."
  @callback boot(env_id :: String.t(), spec(), Config.t()) :: :ok | {:error, String.t()}

  @doc "Whether the VM is running."
  @callback running?(env_id :: String.t(), Config.t()) :: boolean()

  @doc """
  Pauses the VM, writes its memory and device state to `dir` (which
  mustn't exist yet), and stops it. On failure the VM carries on running.
  """
  @callback snapshot(env_id :: String.t(), dir :: Path.t(), Config.t()) ::
              :ok | {:error, String.t()}

  @doc "Starts the VM from its snapshot (the VM's `snapshot` directory), running."
  @callback restore(env_id :: String.t(), spec(), Config.t()) :: :ok | {:error, String.t()}

  @doc "Shuts the guest down, and stops the VM if it doesn't go within `timeout`."
  @callback power_off(env_id :: String.t(), timeout(), Config.t()) :: :ok | {:error, String.t()}

  @doc "Stops the VM at once."
  @callback kill(env_id :: String.t(), Config.t()) :: :ok | {:error, String.t()}

  @doc "Stops the VM and gives back its tap and address."
  @callback release(env_id :: String.t(), Config.t()) :: :ok | {:error, String.t()}

  @doc "Total CPU time (microseconds) and memory (bytes) of each running VM."
  @callback usage([String.t()], Config.t()) :: %{
              String.t() => %{cpu_usec: non_neg_integer(), memory_bytes: non_neg_integer()}
            }

  def impl(%Config{machine: machine}), do: machine
end
