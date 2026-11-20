defmodule ForemanAgent.VM.Reclaimer do
  @moduledoc """
  Asks quiet environment VMs to give their page cache back to the box
  when the box runs short of memory (see `ForemanAgent.Guest.Reclaim`).

  Every 30 seconds it samples the box's `MemAvailable` and each running
  VM's CPU and memory from its cgroup, which the guest can't make
  smaller. A VM is quiet from the first sample it used no more than half
  a core since the one before, until a sample it used more. Healthchecks
  and file watchers keep an idle VM above a tenth of a core, and the box
  sees more than the guest does, since every vCPU wakes for each one: an
  idle VM running #200's compose stack, healthchecked every second,
  measured 0.13 cores in the guest and 0.25 to 0.30 from the box. A build
  takes several cores.

  When less than `FOREMAN_VM_RECLAIM_BELOW` percent of the box's memory is
  available (20 by default; 0 turns it off), it asks VMs that have been
  quiet for ten minutes or more, longest quiet first, then biggest, to
  reclaim all but `FOREMAN_VM_RECLAIM_KEEP_MB` of their page cache (2048),
  until what the guests say they freed covers the gap to five points past
  the threshold. VMs that aren't quiet aren't asked.

  What a guest frees isn't what the box gets back: free page reporting
  only reports free blocks of 2 MiB or more, and takes up to a minute. So
  after a round it waits 90 seconds and measures again before asking any
  more, and a guest that freed less than it said, or lied, only moves the
  box on to the next VM. A VM is asked again once it has grown a GiB past
  where it settled after its last reclaim, or an hour after it.

  With `FOREMAN_VM_RECLAIM_IDLE_MINUTES` set, a VM quiet that long is also
  asked once per quiet stretch, whatever the box has free.

  A guest that can't reclaim (its system image or agent is older) isn't
  asked again until its VM starts again; one that fails, its writes in
  the guest included, is asked again ten minutes later. The reclaims of a round run in a process of their
  own, one VM at a time, while the samples go on.

  The policy is pure (`observe/3`, `plan/4`, `still?/2`, `run_round/4`,
  `record/3`); the server feeds it. Each VM is checked against the latest
  sample just before it's asked, so one that got busy while an earlier
  guest took its time isn't, and each outcome is taken in as it comes,
  for the run of the VM that was asked.
  """
  use GenServer

  alias ForemanAgent.{Config, VM}
  alias ForemanAgent.VM.{Link, Links, Machine}

  require Logger

  @every 30_000
  @quiet_cpu 0.5
  @quiet_for 10 * 60_000
  # Free page reporting's tail, measured at up to a minute.
  @settle 90_000
  @regrow 1_073_741_824
  @ask_again 60 * 60_000
  @retry 10 * 60_000
  # The gap is filled to this many points past the threshold.
  @headroom 5
  # Less than this past what it would keep isn't worth asking for.
  @worth 512 * 1_048_576
  @reclaim_timeout 60_000
  @connect_timeout 10_000
  @mib 1_048_576

  @type sample :: %{
          available_bytes: non_neg_integer(),
          total_bytes: non_neg_integer(),
          vms: %{String.t() => %{cpu_usec: non_neg_integer(), memory_bytes: non_neg_integer()}}
        }

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "A policy that has seen nothing yet."
  def new, do: %{vms: %{}, settle_until: nil}

  @doc """
  Takes a sample in at `now` (monotonic milliseconds). A VM missing from
  it has stopped and is forgotten; one whose CPU counter went back has
  started again and starts over.
  """
  def observe(state, %{vms: vms}, now) do
    %{state | vms: Map.new(vms, fn {id, line} -> {id, observe_vm(state.vms[id], line, now)} end)}
  end

  defp observe_vm(%{cpu_usec: before} = vm, %{cpu_usec: cpu} = line, now) when cpu >= before do
    busy = (cpu - before) / (max(now - vm.seen_at, 1) * 1000)
    settling? = vm.reclaimed_at != nil and vm.settled_bytes == nil

    %{
      vm
      | cpu_usec: cpu,
        memory_bytes: line.memory_bytes,
        seen_at: now,
        quiet_since: if(busy > @quiet_cpu, do: nil, else: vm.quiet_since || vm.seen_at),
        settled_bytes:
          if(settling? and now - vm.reclaimed_at >= @settle,
            do: line.memory_bytes,
            else: vm.settled_bytes
          )
    }
  end

  defp observe_vm(_vm, line, now) do
    %{
      # Which run of the VM this is: an outcome for an earlier one is dropped.
      incarnation: System.unique_integer([:positive, :monotonic]),
      cpu_usec: line.cpu_usec,
      memory_bytes: line.memory_bytes,
      seen_at: now,
      quiet_since: nil,
      reclaimed_at: nil,
      settled_bytes: nil,
      retry_at: nil,
      unsupported: false
    }
  end

  @doc """
  Which VMs to ask now, in order, each `%{id, reason, memory, incarnation,
  quiet_since}` (`reason` is `:pressure` or `:timer`), and the bytes the
  box is short of (0 without pressure). `nil` for none.
  """
  def plan(state, sample, now, settings) do
    if state.settle_until != nil and now < state.settle_until do
      nil
    else
      {pressure, deficit} = pressure(state, sample, now, settings)
      asked = MapSet.new(pressure, & &1.id)
      timer = Enum.reject(timer(state, now, settings), &MapSet.member?(asked, &1.id))

      case pressure ++ timer do
        [] -> nil
        ask -> %{ask: ask, deficit: deficit}
      end
    end
  end

  defp pressure(state, sample, now, settings) do
    %{available_bytes: available, total_bytes: total} = sample

    if settings.below > 0 and available * 100 < total * settings.below do
      deficit = div(total * min(settings.below + @headroom, 100), 100) - available

      ask =
        state.vms
        |> Enum.filter(fn {_id, vm} -> askable?(vm, now, settings) and pressure?(vm, now) end)
        |> Enum.sort_by(fn {_id, vm} -> {vm.quiet_since, -vm.memory_bytes} end)
        |> Enum.map(fn {id, vm} -> item(id, vm, :pressure) end)

      {ask, deficit}
    else
      {[], 0}
    end
  end

  defp timer(_state, _now, %{idle_minutes: nil}), do: []

  defp timer(state, now, settings) do
    for {id, vm} <- Enum.sort_by(state.vms, fn {_id, vm} -> vm.quiet_since end),
        askable?(vm, now, settings),
        quiet_for?(vm, now, settings.idle_minutes * 60_000),
        vm.reclaimed_at == nil or vm.reclaimed_at < vm.quiet_since,
        do: item(id, vm, :timer)
  end

  defp item(id, vm, reason) do
    %{
      id: id,
      reason: reason,
      memory: vm.memory_bytes,
      incarnation: vm.incarnation,
      quiet_since: vm.quiet_since
    }
  end

  @doc """
  Whether a VM planned for may still be asked: the same run of it, quiet
  since the same sample as when the plan was made, and able to reclaim.
  """
  def still?(state, %{id: id, incarnation: incarnation, quiet_since: quiet_since}) do
    match?(
      %{incarnation: ^incarnation, quiet_since: ^quiet_since, unsupported: false},
      state.vms[id]
    )
  end

  defp askable?(vm, now, settings) do
    not vm.unsupported and (vm.retry_at == nil or now >= vm.retry_at) and
      vm.memory_bytes > settings.keep_mb * @mib + @worth
  end

  defp pressure?(vm, now) do
    quiet_for?(vm, now, @quiet_for) and
      (vm.reclaimed_at == nil or now - vm.reclaimed_at >= @ask_again or
         (vm.settled_bytes != nil and vm.memory_bytes >= vm.settled_bytes + @regrow))
  end

  defp quiet_for?(vm, now, ms), do: vm.quiet_since != nil and now - vm.quiet_since >= ms

  @doc """
  Asks each VM in the plan in turn (`reclaim.(env_id, keep_mb)`), until
  what the guests say they freed covers the plan's deficit; `:timer` ones
  are asked anyway. A guest's word counts for no more than its VM holds,
  and for nothing when its writes failed. Returns `{item, result, at}`
  for each VM asked.

  Options: `:allowed?` (`fn item -> boolean end`, asked just before each
  VM: the server checks the VM is still quiet), `:report` (`fn outcome ->
  any end`, called with each outcome as it comes) and `:clock`.
  """
  def run_round(%{ask: ask, deficit: deficit}, keep_mb, reclaim, opts \\ []) do
    allowed? = Keyword.get(opts, :allowed?, fn _item -> true end)
    report = Keyword.get(opts, :report, fn _outcome -> :ok end)
    clock = Keyword.get(opts, :clock, &now/0)

    {outcomes, _freed} =
      Enum.reduce(ask, {[], 0}, fn item, {outcomes, freed} ->
        if (item.reason == :timer or freed < deficit) and allowed?.(item) do
          result = reclaim.(item.id, keep_mb)
          log(item.id, result)
          outcome = {item, result, clock.()}
          report.(outcome)
          {[outcome | outcomes], freed + counted(result, item.memory)}
        else
          {outcomes, freed}
        end
      end)

    Enum.reverse(outcomes)
  end

  defp counted({:ok, %{reclaim: r} = result}, memory) when r in ["ok", "partial"],
    do: min(max(result.free_after_mb - result.free_before_mb, 0) * @mib, memory)

  defp counted(_result, _memory), do: 0

  defp log(id, {:ok, %{reclaim: "failed"} = r}) do
    Logger.warning(
      "couldn't reclaim memory from #{id}: the guest's writes failed " <>
        "(reclaim failed, compact #{r.compact}, drain #{r.drain})"
    )
  end

  defp log(id, {:ok, %{reclaim: "skipped"} = r}) do
    Logger.info("#{id} has #{r.file_before_mb} MiB of page cache, about what it keeps")
  end

  # A drain that failed leaves the reclaim standing, but less of it may
  # come back to the box.
  defp log(id, {:ok, r}) do
    message =
      "reclaimed memory from #{id}: file cache #{r.file_before_mb} to #{r.file_after_mb} MiB, " <>
        "#{max(r.free_after_mb - r.free_before_mb, 0)} MiB freed in the guest " <>
        "(reclaim #{r.reclaim} in #{r.reclaim_ms} ms, compact #{r.compact} in #{r.compact_ms} ms, " <>
        "drain #{r.drain} in #{r.drain_ms} ms)"

    if r.drain == "failed" do
      Logger.warning(
        message <>
          "; the guest couldn't drain its per-CPU free lists, so less may come back " <>
          "(its journal says why)"
      )
    else
      Logger.info(message)
    end
  end

  defp log(id, {:error, :unsupported}),
    do:
      Logger.info(
        "#{id}'s VM can't reclaim its page cache until it starts again on a newer image"
      )

  defp log(id, {:error, reason}) when is_binary(reason),
    do: Logger.warning("couldn't reclaim #{id}'s page cache: #{reason}")

  defp log(id, {:error, reason}),
    do: Logger.warning("couldn't reclaim #{id}'s page cache: #{inspect(reason)}")

  @doc """
  Takes outcomes in at `now`. A VM that reclaimed settles, and nothing
  more is asked until the memory has had time to come back. One with
  little cache to give isn't asked again until it grows, one that can't
  isn't asked again while it runs, and one that failed (its writes in
  the guest included) waits. An outcome for an earlier run of the VM is
  dropped.
  """
  def record(state, outcomes, now) do
    Enum.reduce(outcomes, state, fn {%{id: id, incarnation: incarnation}, result, at}, state ->
      case state.vms do
        %{^id => %{incarnation: ^incarnation} = vm} ->
          state = %{state | vms: Map.put(state.vms, id, outcome(vm, result, at))}
          if reclaimed?(result), do: %{state | settle_until: now + @settle}, else: state

        _ ->
          state
      end
    end)
  end

  defp reclaimed?({:ok, %{reclaim: r}}), do: r in ["ok", "partial"]
  defp reclaimed?(_result), do: false

  defp outcome(vm, {:ok, %{reclaim: r}}, at) when r in ["ok", "partial"],
    do: %{vm | reclaimed_at: at, settled_bytes: nil, retry_at: nil}

  defp outcome(vm, {:ok, %{reclaim: "skipped"}}, at),
    do: %{vm | reclaimed_at: at, settled_bytes: vm.memory_bytes, retry_at: nil}

  defp outcome(vm, {:error, :unsupported}, _at), do: %{vm | unsupported: true}
  defp outcome(vm, _failed, at), do: %{vm | retry_at: at + @retry}

  @doc "This box's sample: `MemAvailable`, `MemTotal`, and each running VM's cgroup."
  @spec sample(Config.t()) :: {:ok, sample()} | {:error, String.t()}
  def sample(config) do
    machine = Machine.impl(config)

    with {:ok, text} <- File.read(Path.join(config.proc, "meminfo")),
         [_, total] <- Regex.run(~r/^MemTotal:\s+(\d+) kB$/m, text),
         [_, available] <- Regex.run(~r/^MemAvailable:\s+(\d+) kB$/m, text) do
      running = config |> VM.list() |> Enum.filter(&machine.running?(&1, config))

      {:ok,
       %{
         available_bytes: String.to_integer(available) * 1024,
         total_bytes: String.to_integer(total) * 1024,
         vms: machine.usage(running, config)
       }}
    else
      _ -> {:error, "couldn't read the box's memory from #{config.proc}/meminfo"}
    end
  end

  @doc """
  Asks an environment's VM to reclaim its page cache past `keep_mb` (see
  `Link.reclaim/3`), once its guest agent answers.
  """
  def reclaim(env_id, keep_mb, config) do
    case Links.await(env_id, config, @connect_timeout) do
      :ok -> Link.reclaim(Links.get(env_id, config), keep_mb, @reclaim_timeout)
      :timeout -> {:error, "the environment's VM isn't answering"}
    end
  end

  @impl true
  def init(opts) do
    config = fn -> Keyword.get_lazy(opts, :config, &Config.get/0) end

    state = %{
      policy: new(),
      every: Keyword.get(opts, :every, @every),
      sample: Keyword.get_lazy(opts, :sample, fn -> fn -> sample(config.()) end end),
      reclaim:
        Keyword.get_lazy(opts, :reclaim, fn ->
          fn id, keep_mb -> reclaim(id, keep_mb, config.()) end
        end),
      now: Keyword.get(opts, :now, &now/0),
      settings: Keyword.get_lazy(opts, :settings, fn -> settings(config.()) end),
      round: nil,
      warned: nil
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state)

    case take_sample(state) do
      {:ok, sample} ->
        now = state.now.()
        state = %{state | policy: observe(state.policy, sample, now), warned: nil}
        {:noreply, maybe_start_round(state, sample, now)}

      {:error, message} ->
        if message != state.warned, do: Logger.warning(message)
        {:noreply, %{state | warned: message}}
    end
  end

  def handle_info({:outcome, ref, outcome}, %{round: {_pid, ref}} = state),
    do: {:noreply, %{state | policy: record(state.policy, [outcome], state.now.())}}

  def handle_info({:round_done, ref}, %{round: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | round: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{round: {_pid2, ref}} = state) do
    Logger.warning("a page cache reclaim round failed: #{inspect(reason)}")
    {:noreply, %{state | round: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:still?, ref, item}, _from, %{round: {_pid, ref}} = state),
    do: {:reply, still?(state.policy, item), state}

  def handle_call({:still?, _ref, _item}, _from, state), do: {:reply, false, state}

  defp maybe_start_round(%{round: nil} = state, sample, now) do
    case plan(state.policy, sample, now, state.settings) do
      nil ->
        state

      plan ->
        server = self()
        %{reclaim: reclaim, now: clock, settings: %{keep_mb: keep_mb}} = state

        {pid, ref} =
          spawn_monitor(fn ->
            ref =
              receive do
                {:go, ref} -> ref
              end

            run_round(plan, keep_mb, reclaim,
              clock: clock,
              allowed?: &GenServer.call(server, {:still?, ref, &1}, 30_000),
              report: &send(server, {:outcome, ref, &1})
            )

            send(server, {:round_done, ref})
          end)

        send(pid, {:go, ref})
        %{state | round: {pid, ref}}
    end
  end

  defp maybe_start_round(state, _sample, _now), do: state

  defp take_sample(state) do
    state.sample.()
  rescue
    e -> {:error, "couldn't sample the box for reclaim: #{Exception.message(e)}"}
  end

  # Out-of-range settings are pulled in rather than refused: a box with
  # FOREMAN_VM_RECLAIM_BELOW=200 still runs.
  @doc false
  def settings(config) do
    %{
      below: config.vm_reclaim_below |> max(0) |> min(95),
      keep_mb: max(config.vm_reclaim_keep_mb, 0),
      idle_minutes:
        case config.vm_reclaim_idle_minutes do
          minutes when is_integer(minutes) and minutes > 0 -> minutes
          _ -> nil
        end
    }
  end

  defp schedule(%{every: :manual}), do: :ok
  defp schedule(%{every: every}), do: Process.send_after(self(), :tick, every)

  defp now, do: System.monotonic_time(:millisecond)
end
