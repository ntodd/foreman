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
  def adopt(env_id, nonce, guest, config) do
    case Helper.request(config, ["adopt", env_id, nonce, guest], 105_000) do
      {:ok, _} ->
        :ok

      {:error, "unknown request"} ->
        {:error, "re-run the install script to enable prebuild adoption"}

      error ->
        error
    end
  end

  @impl true
  def stop_adoption(nonce, config) do
    with {:ok, _} <- Helper.request(config, ["stop-adopt", nonce]), do: :ok
  end

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
  def running([id], config), do: if(running?(id, config), do: [id], else: [])

  def running(env_ids, config) do
    # Bound argv and the time spent in a single systemd query on large boxes.
    env_ids |> Enum.chunk_every(64) |> Enum.flat_map(&running_batch(&1, config))
  end

  defp running_batch(ids, config) do
    args = ["is-active" | Enum.map(ids, &unit/1)]

    # Without --quiet, systemctl prints one state per explicit unit, in order.
    # A failed or incomplete call mustn't shift one VM's state onto another.
    with {:ok, %{status: status, output: text}} when status in [0, 3, 4] <-
           ForemanAgent.Runner.run("systemctl", args, timeout: 2_000),
         states = String.split(text, "\n", trim: true),
         true <- length(states) == length(ids) do
      for {id, state} <- Enum.zip(ids, states), state in ~w(active reloading refreshing), do: id
    else
      _ -> Enum.filter(ids, &running?(&1, config))
    end
  end

  @impl true
  def inventory_state(env_id, _config) do
    args = ["show", "--property=LoadState,ActiveState,Result,ExecMainExitTimestamp", unit(env_id)]
    opts = [env: %{"TZ" => "UTC", "LC_ALL" => "C"}, timeout: 2_000]

    case ForemanAgent.Runner.run("systemctl", args, opts) do
      {:ok, %{status: 0, output: text}} ->
        unit_state(text)

      # A stopped transient unit can have been collected by systemd.
      {:ok, %{status: 4, output: text}} ->
        properties = String.split(text, "\n")

        if "LoadState=not-found" in properties and "ActiveState=inactive" in properties,
          do: :stopped,
          else: :unknown

      _ ->
        :unknown
    end
  end

  defp unit_state(text) do
    properties = String.split(text, "\n")

    cond do
      "ActiveState=active" in properties or "ActiveState=reloading" in properties -> :running
      "Result=oom-kill" in properties -> oom_exit(text)
      "ActiveState=inactive" in properties or "ActiveState=failed" in properties -> :stopped
      true -> :unknown
    end
  end

  defp oom_exit(text) do
    with [_, date, time] <-
           Regex.run(
             ~r/^ExecMainExitTimestamp=\w+ (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) UTC$/m,
             text
           ),
         {:ok, at, 0} <- DateTime.from_iso8601("#{date}T#{time}Z") do
      {:oom_kill, DateTime.to_unix(at)}
    else
      _ -> :stopped
    end
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
    case api_request(config, env_id, :get, "vm.info", receive_timeout: 5_000) do
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
           tap: tap,
           cpus: spec.cpus,
           memory_mb: spec.memory_mb
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
      {:ok, _} ->
        for kind <- [:api, :vsock], do: File.rm(VM.socket_pin(config, env_id, kind))
        :ok

      {:error, message} ->
        {:error, "couldn't release the environment's VM: #{message}"}
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
    case api_request(config, env_id, method, endpoint, opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_request(config, env_id, method, endpoint, opts) do
    with {:ok, socket} <- VM.pin_socket(config, env_id, :api) do
      defaults = [
        method: method,
        url: "http://localhost/api/v1/#{endpoint}",
        unix_socket: socket,
        retry: false,
        receive_timeout: 10_000
      ]

      Req.request(Keyword.merge(defaults, opts))
    end
  end
end
