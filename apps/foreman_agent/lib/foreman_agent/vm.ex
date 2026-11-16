defmodule ForemanAgent.VM do
  @moduledoc """
  Environment VMs on this box: one Cloud Hypervisor VM per environment,
  with the agent in guest mode inside it (see `ForemanAgent.Guest`).

  Layout, per environment:

      <vm_root>/<env_id>/vm.json      what the agent knows about the VM (slug, size, guest image)
      <vm_root>/<env_id>/root.raw     its copy of the guest system image
      <vm_root>/<env_id>/data.raw     its own disk: Docker's data, the clone, the guest agent's state
      <vm_root>/<env_id>/api.sock     Cloud Hypervisor's API
      <vm_root>/<env_id>/vsock.sock   the hybrid vsock the agent talks to the guest on
      <vm_root>/<env_id>/serial.log   the guest's console
      <guest_root>/<sha256>/          the guest system image (vmlinuz, root.raw)
      <agent_disks>/<version>.img     this agent's release, the guest's agent disk

  The VM runs in a systemd unit of its own (`foreman-vm-<env_id>`), which
  the root helper `foreman-vmctl` starts (see `ForemanAgent.VM.Helper`),
  so it outlives the agent's restarts and updates.
  """

  alias ForemanAgent.Config
  alias ForemanProtocol.Schema

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "The files of an environment's VM."
  @spec paths(Config.t(), String.t()) :: map()
  def paths(config, env_id) do
    dir = Path.join(config.vm_root, env_id)

    %{
      dir: dir,
      meta: Path.join(dir, "vm.json"),
      root: Path.join(dir, "root.raw"),
      data: Path.join(dir, "data.raw"),
      snapshot: Path.join(dir, "snapshot"),
      api: Path.join(dir, "api.sock"),
      vsock: Path.join(dir, "vsock.sock"),
      serial: Path.join(dir, "serial.log")
    }
  end

  @doc "Whether an environment's VM is saved to disk (suspended)."
  @spec suspended?(Config.t(), String.t()) :: boolean()
  def suspended?(config, env_id),
    do: File.regular?(Path.join(paths(config, env_id).snapshot, "config.json"))

  @doc "The environments with a VM on this box."
  @spec list(Config.t()) :: [String.t()]
  def list(config) do
    case File.ls(config.vm_root) do
      {:ok, names} -> Enum.filter(names, &(&1 =~ @uuid and File.regular?(paths(config, &1).meta)))
      {:error, _} -> []
    end
  end

  @doc "What the agent recorded about an environment's VM."
  @spec read_meta(Config.t(), String.t()) :: {:ok, map()} | {:error, :none}
  def read_meta(config, env_id) do
    with {:ok, json} <- File.read(paths(config, env_id).meta),
         {:ok, %{"slug" => slug} = meta} when is_binary(slug) <- JSON.decode(json) do
      {:ok, meta}
    else
      _ -> {:error, :none}
    end
  end

  @spec write_meta(Config.t(), String.t(), map()) :: :ok
  def write_meta(config, env_id, meta) do
    path = paths(config, env_id).meta
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(meta))
    File.rename!(tmp, path)
  end

  @doc """
  A VM's size: the environment's limits where it has them (whole CPUs,
  rounded up), the box's defaults otherwise, never more than the box has.
  """
  @spec size(map(), Config.t(), %{cpus: pos_integer(), memory_mb: pos_integer()}) ::
          %{cpus: pos_integer(), memory_mb: pos_integer()}
  def size(limits, config, box) do
    cpus =
      case limits do
        %{cpus: cpus} when is_number(cpus) and cpus > 0 -> ceil(cpus)
        _ -> config.vm_cpus
      end

    memory =
      case limits do
        %{memory_mb: mb} when is_integer(mb) and mb > 0 -> mb
        _ -> config.vm_memory_mb
      end

    %{
      cpus: cpus |> min(box.cpus) |> max(1),
      memory_mb: memory |> min(box.memory_mb) |> max(512)
    }
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
