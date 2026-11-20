defmodule ForemanAgent.VM.Status do
  @moduledoc """
  What a box with environment VMs reports: its inventory, the ports
  listening in its environments, their usage, whether it can run VMs at
  all, and the housekeeping (`box.gc`) that goes with them.

  Inventory and ports come from the agent in each running VM, so they're
  checked here before anything goes on: an entry has to be for the VM's
  own environment. Usage comes from each VM's cgroup on the box, which
  the guest can't touch.
  """

  alias ForemanAgent.{Identity, Ops, Stats, Updater, VM}
  alias ForemanAgent.VM.{Helper, Link, Links, Machine, Prebuild}
  alias ForemanProtocol.{Command, Event}

  @query_timeout 3_000

  @doc """
  Every environment with a VM on this box. One whose VM is running gets
  its state and containers from the guest; one whose guest doesn't answer
  shows as partly running; one whose VM is off is stopped.
  """
  @spec inventory(ForemanAgent.Config.t()) :: {:ok, [map()]}
  def inventory(config) do
    machine = Machine.impl(config)

    envs =
      config
      |> VM.list(:all)
      |> Task.async_stream(&entry(&1, config, machine),
        max_concurrency: 8,
        timeout: @query_timeout * 3,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, nil} -> []
        {:ok, entry} -> [entry]
        {:exit, _} -> []
      end)
      |> Enum.sort_by(& &1.env_id)

    {:ok, envs}
  end

  defp entry(env_id, config, machine) do
    case VM.read_meta(config, env_id) do
      {:ok, %{"kind" => "prebuild"}} ->
        nil

      {:ok, %{"slug" => slug} = record} ->
        base = %{env_id: env_id, slug: slug, containers: []}

        case machine.inventory_state(env_id, config) do
          :running ->
            with_size(guest_entry(env_id, slug, base, config), VM.boot_size(record))

          {:oom_kill, at} ->
            Map.merge(base, %{state: "stopped", oom_killed_at: at})

          :stopped ->
            if VM.suspended?(config, env_id),
              do: with_size(Map.put(base, :state, "suspended"), VM.resume_size(record, config)),
              else: Map.put(base, :state, "stopped")
        end

      {:error, :none} ->
        nil
    end
  end

  defp with_size(entry, nil), do: entry
  defp with_size(entry, size), do: Map.put(entry, :vm_size, size)

  defp guest_entry(env_id, slug, base, config) do
    with {:ok, entries} <- Link.query(Links.get(env_id, config), "inventory", @query_timeout),
         {:ok, entry} <- VM.cast_inventory_entry(entries, env_id, slug) do
      entry
    else
      # Running, without its containers: nothing up yet, or taken down by hand.
      :error -> Map.put(base, :state, "stopped")
      # Running, and its agent isn't answering.
      {:error, _} -> Map.put(base, :state, "partial")
    end
  end

  @doc "The ports listening in each running environment, as `box.ports` has them."
  @spec ports(ForemanAgent.Config.t()) :: map()
  def ports(config) do
    machine = Machine.impl(config)

    config
    |> VM.list()
    |> machine.running(config)
    |> Task.async_stream(&{&1, Link.query(Links.get(&1, config), "ports", @query_timeout)},
      max_concurrency: 8,
      timeout: @query_timeout * 3,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {env_id, {:ok, %{} = report}}}, acc ->
        case Event.new("box.ports", %{environments: Map.take(report, [env_id])}) do
          {:ok, %Event{payload: %{environments: %{^env_id => ports}}}} ->
            Map.put(acc, env_id, ports)

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  @doc """
  The box's capacity and each running VM's usage: CPU over a one-second
  sample (percent of one core) and memory, from its cgroup.
  """
  @spec stats(map()) :: {:ok, map()}
  def stats(ctx) do
    config = ctx.config
    machine = Machine.impl(config)
    box = VM.box_size(config.proc)
    {disk_mb, free_mb} = Stats.disk(ctx)
    running = machine.running(VM.list(config), config)
    trim_consoles(ctx, running)

    before = machine.usage(running, config)
    started = System.monotonic_time(:microsecond)
    if running != [], do: Process.sleep(1_000)
    later = machine.usage(running, config)
    elapsed = max(System.monotonic_time(:microsecond) - started, 1)

    environments =
      for {env_id, %{} = now} <- later, %{} = prior <- [before[env_id]], into: %{} do
        cpu = max(now.cpu_usec - prior.cpu_usec, 0) / elapsed * 100

        {env_id, %{cpu_percent: Float.round(cpu, 2), memory_mb: div(now.memory_bytes, 1_048_576)}}
      end

    {:ok,
     %{
       capacity: %{
         cpus: box.cpus,
         memory_mb: box.memory_mb,
         disk_mb: disk_mb,
         disk_free_mb: free_mb
       },
       environments: environments
     }}
  end

  @doc """
  Prunes Docker in every running VM, drops guest images and agent disks
  no VM uses any more, and the VMs of prebuilds nothing is building (an
  agent that stopped mid-build leaves one). With `prebuilds` (the ones the
  control plane knows on this box), deletes the box's others.
  """
  @spec gc(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def gc(ctx, payload \\ %{}) do
    config = ctx.config
    machine = Machine.impl(config)
    envs = VM.list(config)

    # First, before anything slow: a build started after the control plane
    # listed its prebuilds can't have finished yet.
    with %{prebuilds: known} when is_list(known) <- payload,
         do: prune_prebuilds(config, known, ctx)

    # Every VM at once, each with a deadline: one guest that never answers
    # doesn't hold up the others, or the pruning on the box after.
    timeout = config.vm_relay_gc_timeout

    failures =
      envs
      |> machine.running(config)
      |> Task.async_stream(
        fn env_id ->
          {:ok, cmd} = Command.new("box.gc", %{})
          ctx.log.("info", "Pruning Docker in #{env_id}\n")
          {env_id, Link.run(Links.get(env_id, config), cmd, ctx.log, timeout: timeout)}
        end,
        max_concurrency: 4,
        timeout: timeout + 5_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {_env_id, {:ok, _}}} -> []
        {:ok, {env_id, {:error, message}}} -> [{env_id, message}]
        {:ok, {env_id, {:error, message, _}}} -> [{env_id, message}]
        {:exit, reason} -> [{"a VM", inspect(reason)}]
      end)

    in_flight = in_flight()

    # Marked as a prebuild's, not merely missing from the list above: an
    # environment made since that list was taken is no prebuild.
    cleanup_failures =
      for id <- VM.list(config, :all),
          {:ok, %{"kind" => "prebuild"} = meta} <- [VM.read_meta(config, id)],
          meta["op_id"] not in in_flight do
        ctx.log.("info", "Removing the VM of a prebuild nothing is building (#{id})\n")

        case Prebuild.discard(config, id) do
          :ok -> []
          {:error, reason} -> [{id, reason}]
        end
      end

    metas =
      for env_id <- VM.list(config, :all),
          {:ok, meta} <- [VM.read_meta(config, env_id)],
          do: meta

    prune(
      config.guest_root,
      MapSet.new([config.guest_sha256 | Enum.map(metas, & &1["guest"])]),
      ctx
    )

    prune(
      config.agent_disks,
      MapSet.new([Identity.version() | Enum.map(metas, & &1["agent"])], &"#{&1}.img"),
      ctx
    )

    case failures ++ List.flatten(cleanup_failures) do
      [] -> {:ok, %{}}
      errors -> {:error, Enum.map_join(errors, "; ", fn {id, m} -> "#{id}: #{m}" end)}
    end
  end

  defp prune_prebuilds(config, known, ctx) do
    case File.ls(config.prebuilds_root) do
      {:ok, names} ->
        for name <- names, name =~ ~r/\A[0-9a-f-]{36}\z/, name not in known do
          ctx.log.(
            "info",
            "Removing the prebuild #{name}, which the control plane doesn't know\n"
          )

          File.rm_rf(Path.join(config.prebuilds_root, name))
        end

      {:error, _} ->
        :ok
    end
  end

  defp in_flight do
    Ops.in_flight()
  catch
    :exit, _ -> []
  end

  # Work in progress is a dot-name (a download being unpacked, an agent
  # disk being made): left alone unless it's hours old, which means
  # whatever made it was stopped.
  @stale_work_seconds 6 * 3600

  defp prune(dir, keep, ctx) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, name not in keep, unused?(dir, name) do
          ctx.log.("info", "Removing #{Path.join(dir, name)}\n")
          File.rm_rf(Path.join(dir, name))
        end

      {:error, _} ->
        :ok
    end
  end

  defp unused?(dir, "." <> _ = name) do
    case File.lstat(Path.join(dir, name), time: :posix) do
      {:ok, %{mtime: mtime}} -> :os.system_time(:second) - mtime > @stale_work_seconds
      {:error, _} -> false
    end
  end

  defp unused?(_dir, _name), do: true

  # A guest can write its console without end, and the box's disk holds
  # every VM's: past this, it starts again. Cloud Hypervisor's own log too.
  @console_max 16 * 1024 * 1024

  defp trim_consoles(ctx, env_ids) do
    config = ctx.config
    script = Application.app_dir(:foreman_agent, "priv/vm/trim-log.cjs")

    for env_id <- env_ids,
        path <- [
          VM.paths(config, env_id).serial,
          Path.join(VM.paths(config, env_id).dir, "ch.log")
        ],
        match?({:ok, %{type: :regular, size: size}} when size > @console_max, File.lstat(path)) do
      ctx.runner.run(config.node, [script, path, Integer.to_string(@console_max)], timeout: 5_000)
    end

    :ok
  end

  @doc """
  Whether this box can run environment VMs, for the control plane (the
  join's `vm`): the reason it can't when it can't (a kernel without
  Landlock among them), whether its VMs are nested (the box is itself a
  VM), and whether its disks can reflink.
  """
  @spec report(ForemanAgent.Config.t()) :: map()
  def report(config) do
    reason =
      cond do
        Updater.target() != "linux-amd64" ->
          "environment VMs aren't supported on #{Updater.target()} yet"

        not (is_binary(config.guest_url) and is_binary(config.guest_sha256)) ->
          "this agent wasn't built with a guest image"

        not File.exists?("/dev/kvm") ->
          "this box has no /dev/kvm (KVM, or nested virtualization, is off)"

        true ->
          # A helper that's too old, or a kernel without Landlock, which
          # every VM is confined with.
          case Helper.ready(config) do
            :ok -> nil
            {:error, why} -> why
          end
      end

    host = VM.box_size(config.proc)
    defaults = VM.size(%{}, config, host)

    %{
      ready: reason == nil,
      nested: nested?(),
      reflink: reflink?(config),
      default_cpus: defaults.cpus,
      default_memory_mb: defaults.memory_mb,
      host_cpus: host.cpus,
      host_memory_mb: host.memory_mb
    }
    |> then(&if(reason, do: Map.put(&1, :reason, reason), else: &1))
  end

  # A box that's a VM itself runs its environments nested, which is slower.
  defp nested? do
    case File.read("/proc/cpuinfo") do
      {:ok, info} -> info =~ ~r/^flags\s*:.*\bhypervisor\b/m
      _ -> false
    end
  end

  # Whether a new environment's disk is a reflink (instant) or a copy.
  # Checked once per boot of the agent.
  defp reflink?(config) do
    case :persistent_term.get({__MODULE__, :reflink}, nil) do
      nil ->
        result = probe_reflink(config.vm_root)
        :persistent_term.put({__MODULE__, :reflink}, result)
        result

      result ->
        result
    end
  end

  defp probe_reflink(dir) do
    a = Path.join(dir, ".reflink-probe")
    b = a <> ".copy"

    try do
      File.write!(a, "probe")
      match?({_, 0}, System.cmd("cp", ["--reflink=always", a, b], stderr_to_stdout: true))
    rescue
      _ -> false
    after
      File.rm(a)
      File.rm(b)
    end
  end
end
