defmodule ForemanAgent.VM do
  @moduledoc """
  Environment VMs on this box: one Cloud Hypervisor VM per environment,
  with the agent in guest mode inside it (see `ForemanAgent.Guest`).

  Layout, per environment:

      <vm_root>/.records/<env_id>.json      what the agent knows about the VM (slug, size, guest image)
      <vm_root>/<env_id>/root.raw     its copy of the guest system image
      <vm_root>/<env_id>/data.raw     its own disk: Docker's data, the clone, the guest agent's state
      <vm_root>/<env_id>/api.sock     Cloud Hypervisor's API
      <vm_root>/<env_id>/vsock.sock   the hybrid vsock the agent talks to the guest on
      <vm_root>/<env_id>/serial.log   the guest's console
      <prebuilds_root>/<id>/data.raw  a prebuild's data disk, which new environments start from
      <guest_root>/<sha256>/          the guest system image (vmlinuz, root.raw)
      <agent_disks>/<version>.img     this agent's release, the guest's agent disk

  The VM runs in a systemd unit of its own (`foreman-vm-<env_id>`), which
  the root helper `foreman-vmctl` starts (see `ForemanAgent.VM.Helper`),
  so it outlives the agent's restarts and updates.
  """

  alias ForemanAgent.{Config, SafeFS}
  alias ForemanAgent.Runner.Local
  alias ForemanProtocol.Schema

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "Remove VM storage, reporting the path that needs operator attention on failure."
  def remove_tree(path) do
    with {:ok, _} <- File.rm_rf(path),
         {:error, :enoent} <- File.lstat(path) do
      :ok
    else
      {:error, reason, file} ->
        {:error, "couldn't remove #{file}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, "couldn't verify removal of #{path}: #{:file.format_error(reason)}"}

      {:ok, _stat} ->
        {:error, "#{path} still exists after removal"}
    end
  end

  @doc "The files of an environment's VM."
  @spec paths(Config.t(), String.t()) :: map()
  def paths(config, env_id) do
    dir = Path.join(config.vm_root, env_id)

    %{
      dir: dir,
      meta: Path.join([config.vm_root, ".records", env_id <> ".json"]),
      legacy_meta: Path.join(dir, "vm.json"),
      root: Path.join(dir, "root.raw"),
      data: Path.join(dir, "data.raw"),
      snapshot: Path.join(dir, "snapshot"),
      api: Path.join(dir, "api.sock"),
      vsock: Path.join(dir, "vsock.sock"),
      serial: Path.join(dir, "serial.log")
    }
  end

  @doc """
  Whether an environment's VM is saved to disk (suspended): a snapshot no
  VM was ever started from. One that was (marked `consumed` before the
  VM could run) is never restored again, whatever became of that VM.

  The VM's directory is the VM's to write, so nothing here follows a
  symlink: a snapshot directory, config or marker that's one isn't a
  snapshot to restore.
  """
  @spec suspended?(Config.t(), String.t()) :: boolean()
  def suspended?(config, env_id) do
    snapshot = paths(config, env_id).snapshot

    match?({:ok, %{type: :directory}}, File.lstat(snapshot)) and
      match?({:ok, %{type: :regular}}, File.lstat(Path.join(snapshot, "config.json"))) and
      File.lstat(Path.join(snapshot, "consumed")) == {:error, :enoent}
  end

  @doc """
  The environments with a VM on this box, or with `:all`, the prebuilds
  being built too (`ForemanAgent.VM.Prebuild`).
  """
  @spec list(Config.t(), :environments | :all) :: [String.t()]
  def list(config, which \\ :environments) do
    all =
      case File.ls(config.vm_root) do
        {:ok, names} ->
          Enum.filter(names, fn id ->
            p = paths(config, id)
            id =~ @uuid and (File.regular?(p.meta) or File.regular?(p.legacy_meta))
          end)

        {:error, _} ->
          []
      end

    if which == :all, do: all, else: Enum.reject(all, &prebuild?(config, &1))
  end

  defp prebuild?(config, id), do: match?({:ok, %{"kind" => "prebuild"}}, read_meta(config, id))

  @doc "What the agent recorded about an environment's VM."
  @spec read_meta(Config.t(), String.t()) :: {:ok, map()} | {:error, :none}
  def read_meta(config, env_id) do
    paths = paths(config, env_id)

    case File.lstat(paths.meta) do
      {:ok, %{type: :regular}} -> decode_record(File.read(paths.meta))
      {:error, :enoent} -> legacy_record(config, paths.legacy_meta)
      _ -> {:error, :none}
    end
  end

  defp decode_record(result) do
    with {:ok, json} <- result,
         {:ok, %{"slug" => slug} = meta} when is_binary(slug) <- JSON.decode(json) do
      {:ok, meta}
    else
      _ -> {:error, :none}
    end
  end

  # Keep inventory and image references during upgrades. Neither resource
  # limits nor authority to delete an abandoned prebuild come from this file.
  defp legacy_record(config, path) do
    script = Application.app_dir(:foreman_agent, "priv/vm/read-legacy-record.cjs")

    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, %{status: 0, output: json}} <-
           Local.run(config.node, [script, path], timeout: 5_000),
         {:ok, record} <- decode_record({:ok, json}) do
      record =
        Map.reject(record, fn {key, value} ->
          key in ["guest", "agent"] and not is_binary(value)
        end)

      booted =
        if is_map(record["booted"]), do: Map.take(record["booted"], ["guest", "agent"]), else: %{}

      {:ok,
       record
       |> Map.take(["slug", "guest", "agent"])
       |> Map.merge(%{"legacy" => true, "booted" => booted})}
    else
      _ -> {:error, :none}
    end
  end

  @doc "The CPU and memory recorded by the host at cold boot."
  def boot_size(%{"booted" => %{"cpus" => cpus, "memory_mb" => mb}})
      when is_integer(cpus) and cpus > 0 and is_integer(mb) and mb > 0,
      do: %{cpus: cpus, memory_mb: mb}

  def boot_size(_record), do: nil

  def snapshot_compatible?(booted, config) do
    booted["guest"] == config.guest_sha256 and booted["agent"] == ForemanAgent.Identity.version()
  end

  def resume_size(%{"booted" => booted} = record, config) do
    if snapshot_compatible?(booted, config), do: boot_size(record)
  end

  def resume_size(_record, _config), do: nil

  @spec write_meta(Config.t(), String.t(), map()) :: :ok
  def write_meta(config, env_id, meta) do
    path = paths(config, env_id).meta
    File.mkdir_p!(Path.dirname(path))
    :ok = SafeFS.write_atomic(path, JSON.encode!(meta), 0o600)
  end

  @doc """
  A VM's size: the environment's limits where it has them (whole CPUs,
  rounded up), the box's defaults otherwise, never more than the box has.
  """
  @spec size(map(), Config.t(), %{cpus: pos_integer(), memory_mb: pos_integer()}) ::
          %{cpus: pos_integer(), memory_mb: pos_integer()}
  def size(limits, config, box) do
    ForemanProtocol.VMSize.resolve(
      limits,
      %{cpus: config.vm_cpus, memory_mb: config.vm_memory_mb},
      box
    )
  end

  @doc "This box's cores and memory, for capping a VM's size."
  @spec box_size(String.t()) :: %{cpus: pos_integer(), memory_mb: pos_integer()}
  def box_size(proc \\ "/proc") do
    cpus = System.schedulers_online()

    memory_mb =
      with {:ok, info} <- File.read(Path.join(proc, "meminfo")),
           [_, kb] <- Regex.run(~r/^MemTotal:\s+(\d+) kB/m, info) do
        div(String.to_integer(kb), 1024)
      else
        _ -> 1024
      end

    %{cpus: cpus, memory_mb: memory_mb}
  end

  # Suspended is the box's to say: a guest that's answering is running.
  @guest_states ForemanProtocol.Event.env_states() -- ["suspended"]

  @inventory_entry {:object,
                    env_id: {:uuid, required: true},
                    slug: {:slug, required: true},
                    state: {{:enum, @guest_states}, required: true},
                    containers:
                      {{:list,
                        {:object,
                         id: {:string, required: true},
                         service: {:string, required: true},
                         state: {:string, required: true}}}, default: []}}

  @doc """
  An inventory entry the guest reported, checked: it has to be for the
  environment the VM belongs to, under the slug the box knows it by.
  """
  @spec cast_inventory_entry(term(), String.t(), String.t()) :: {:ok, map()} | :error
  def cast_inventory_entry(entries, env_id, slug) when is_list(entries) do
    Enum.find_value(entries, :error, fn entry ->
      case Schema.cast(%{"entry" => entry}, entry: {@inventory_entry, required: true}) do
        {:ok, %{entry: %{env_id: ^env_id} = entry}} -> {:ok, %{entry | slug: slug}}
        _ -> nil
      end
    end)
  end

  def cast_inventory_entry(_entries, _env_id, _slug), do: :error
end
