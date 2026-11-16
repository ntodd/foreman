defmodule ForemanAgent.VM.Machine.Cloud do
  @moduledoc """
  Environment VMs under Cloud Hypervisor, each in its own systemd unit
  (`foreman-vm-<env_id>.service`, in `foreman.slice`) that the root
  helper starts. The agent talks to Cloud Hypervisor's API on the VM's
  socket (the VM runs as the agent's user) and reads usage from the
  unit's cgroup.
  """
  @behaviour ForemanAgent.VM.Machine

  alias ForemanAgent.VM
  alias ForemanAgent.VM.Helper

  require Logger

  @cgroup "/sys/fs/cgroup/foreman.slice"

  @impl true
  def boot(env_id, spec, config) do
    paths = VM.paths(config, env_id)
    # What an earlier run left: Cloud Hypervisor won't bind over them.
    Enum.each([paths.api, paths.vsock], &File.rm/1)

    case Helper.start(config, env_id, spec) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, "couldn't start the environment's VM: #{message}"}
    end
  end

  @impl true
  def running?(env_id, _config) do
    case System.cmd("systemctl", ["is-active", "--quiet", unit(env_id)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  @impl true
  def power_off(env_id, timeout, config) do
    if running?(env_id, config) do
      # ACPI's power button: the guest shuts down (Docker stops its
      # containers) and Cloud Hypervisor exits.
      _ = api(config, env_id, :put, "vm.power-button")

      if wait_stopped(env_id, config, timeout) do
        :ok
      else
        Logger.warning("the VM for #{env_id} didn't power off; stopping it")
        kill(env_id, config)
      end
    else
      :ok
    end
  end

  @impl true
  def kill(env_id, config) do
    case Helper.stop(config, env_id) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, "couldn't stop the environment's VM: #{message}"}
    end
  end

  @impl true
  def release(env_id, config) do
    case Helper.release(config, env_id) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, "couldn't release the environment's VM: #{message}"}
    end
  end

  @impl true
  def usage(env_ids, _config) do
    for env_id <- env_ids, usage = read_usage(env_id), into: %{}, do: {env_id, usage}
  end

  defp read_usage(env_id) do
    dir = Path.join(@cgroup, unit(env_id))

    with {:ok, stat} <- File.read(Path.join(dir, "cpu.stat")),
         [_, usec] <- Regex.run(~r/^usage_usec (\d+)$/m, stat),
         {:ok, memory} <- File.read(Path.join(dir, "memory.current")),
         {bytes, _} <- Integer.parse(memory) do
      %{cpu_usec: String.to_integer(usec), memory_bytes: bytes}
    else
      _ -> nil
    end
  end

  defp wait_stopped(env_id, config, timeout) when timeout <= 0, do: not running?(env_id, config)

  defp wait_stopped(env_id, config, timeout) do
    if running?(env_id, config) do
      Process.sleep(250)
      wait_stopped(env_id, config, timeout - 250)
    else
      true
    end
  end

  @doc false
  def unit(env_id), do: "foreman-vm-#{env_id}.service"

  defp api(config, env_id, method, endpoint) do
    socket = VM.paths(config, env_id).api

    case Req.request(
           method: method,
           url: "http://localhost/api/v1/#{endpoint}",
           unix_socket: socket,
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
