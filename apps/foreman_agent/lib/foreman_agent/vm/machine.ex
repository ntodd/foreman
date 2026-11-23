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

  @doc "Whether this host has the helper required for a new boot or restore."
  @callback ready(Config.t()) :: :ok | {:error, String.t()}

  @doc "Initializes a private prebuild clone before publication."
  @callback adopt(String.t(), String.t(), String.t(), Config.t()) :: :ok | {:error, String.t()}

  @callback stop_adoption(String.t(), Config.t()) :: :ok | {:error, String.t()}

  @doc "VM unit state and, for a retained OOM kill, the Unix time of its exit."
  @callback inventory_state(String.t(), Config.t()) ::
              :running | :stopped | :unknown | {:oom_kill, integer()}

  @doc "Boots the VM from its disks."
  @callback boot(env_id :: String.t(), spec(), Config.t()) :: :ok | {:error, String.t()}

  @doc "Whether the VM is running."
  @callback running?(env_id :: String.t(), Config.t()) :: boolean()

  @doc "The running subset of the given VM ids, for periodic box reports."
  @callback running([String.t()], Config.t()) :: [String.t()]

  @doc """
  Pauses the VM, writes its memory and device state to `dir` (which
  mustn't exist yet), and stops it. On failure the VM carries on running.
  """
  @callback snapshot(env_id :: String.t(), dir :: Path.t(), Config.t()) ::
              :ok | {:error, String.t()}

  @doc "Starts the VM from its snapshot (the VM's `snapshot` directory), running."
  @callback restore(env_id :: String.t(), spec(), Config.t()) :: :ok | {:error, String.t()}

  @doc """
  Lets a running VM go on if something paused it and never let it go (a
  suspend cut short). `:ok` for one that wasn't paused.
  """
  @callback unpause(env_id :: String.t(), Config.t()) :: :ok | {:error, String.t()}

  @doc """
  Shuts the guest down, and stops the VM if it doesn't go within `timeout`
  (`:killed`).
  """
  @callback power_off(env_id :: String.t(), timeout(), Config.t()) ::
              :ok | :killed | {:error, String.t()}

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
