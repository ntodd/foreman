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
  alias ForemanAgent.VM.{Helper, SnapshotConfig}

  require Logger

  @cgroup "/sys/fs/cgroup/foreman.slice"

  @impl true
  defdelegate ready(config), to: Helper

  @impl true
  def boot(env_id, spec, config) do
    paths = VM.paths(config, env_id)
    # What an earlier run left: Cloud Hypervisor won't bind over them. Not
    # a running VM's, which the helper leaves running.
    unless running?(env_id, config), do: Enum.each([paths.api, paths.vsock], &File.rm/1)

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
  def snapshot(env_id, dir, config) do
    # Paused already by a suspend that was cut short: pausing again fails.
    _ = unpause(env_id, config)

    with :ok <- api_ok(api(config, env_id, :put, "vm.pause"), "pause"),
         :ok <- snapshot_to(config, env_id, dir) do
      # Stopping the VMM ends the unit; the snapshot is what's left.
      _ = api(config, env_id, :put, "vmm.shutdown")

      if wait_stopped(env_id, config, 30_000), do: :ok, else: kill(env_id, config)
    end
  end

  defp snapshot_to(config, env_id, dir) do
    body = %{"destination_url" => "file://" <> dir}

    case api(config, env_id, :put, "vm.snapshot", json: body, receive_timeout: 600_000) do
      :ok ->
        :ok

      error ->
        # Back to running, as it was.
        _ = api(config, env_id, :put, "vm.resume")
        api_ok(error, "snapshot")
    end
  end

  defp api_ok(:ok, _what), do: :ok
  defp api_ok({:error, reason}, what), do: {:error, "couldn't #{what} the VM: #{inspect(reason)}"}

  @impl true
  def unpause(env_id, config) do
    case vm_state(config, env_id) do
      "Paused" -> api_ok(api(config, env_id, :put, "vm.resume"), "resume")
      _ -> :ok
    end
  end

  defp vm_state(config, env_id) do
    case Req.get(
           url: "http://localhost/api/v1/vm.info",
           unix_socket: VM.paths(config, env_id).api,
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"state" => state}}} -> state
      _ -> nil
    end
  end

  # The snapshot's config is in the VM's directory, which the VM can
  # write, and Cloud Hypervisor restores whatever it says, Landlock
  # included (VM.SnapshotConfig): it has to be the one start gave the VM,
  # with the guest image and agent disk it booted with and the tap the
  # helper gave it.
  @impl true
  def restore(env_id, spec, config) do
    paths = VM.paths(config, env_id)

    with {:ok, tap} <- Helper.tap(config, env_id),
         want = %{
           dir: paths.dir,
           guest: Path.join(config.guest_root, spec.guest),
           agent_disk: Path.join(config.agent_disks, "#{spec.agent_version}.img"),
           tap: tap
         },
         :ok <- SnapshotConfig.check_file(Path.join(paths.snapshot, "config.json"), want),
         _ = unless(running?(env_id, config), do: Enum.each([paths.api, paths.vsock], &File.rm/1)),
         {:ok, _} <- Helper.restore(config, env_id, spec) do
      :ok
    else
      {:error, message} -> {:error, "couldn't resume the environment's VM: #{message}"}
    end
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
        with :ok <- kill(env_id, config), do: :killed
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

  defp api(config, env_id, method, endpoint, opts \\ []) do
    socket = VM.paths(config, env_id).api

    case Req.request(
           [
             method: method,
             url: "http://localhost/api/v1/#{endpoint}",
             unix_socket: socket,
             retry: false,
             receive_timeout: 10_000
           ]
           |> Keyword.merge(opts)
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
