defmodule ForemanAgent.VM.Reclaimer do
  @moduledoc """
  Asks quiet environment VMs to give their page cache back to the box
  when the box runs short of memory (see `ForemanAgent.Guest.Reclaim`).

  Every 30 seconds it samples the box's `MemAvailable` and each running
  VM's CPU and memory from its cgroup, which the guest can't make
  smaller. A VM is quiet from the first sample it used no more than 10%
  of a core since the one before, until a sample it used more.

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
  asked again until its VM starts again; one that fails is asked again
  ten minutes later. The reclaims of a round run in a process of their
  own, one VM at a time, while the samples go on.

  The policy is pure (`observe/3`, `plan/4`, `run_round/4`, `record/3`);
  the server feeds it.
  """
  use GenServer

  alias ForemanAgent.{Config, VM}
  alias ForemanAgent.VM.{Link, Links, Machine}

  require Logger

  @every 30_000
  @quiet_cpu 0.10
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
  Which VMs to ask now, in order, each `{env_id, :pressure | :timer,
  memory_bytes}`, and the bytes the box is short of (0 without pressure).
  `nil` for none.
  """
  def plan(state, sample, now, settings) do
    if state.settle_until != nil and now < state.settle_until do
      nil
    else
      {pressure, deficit} = pressure(state, sample, now, settings)
      asked = MapSet.new(pressure, &elem(&1, 0))
      timer = Enum.reject(timer(state, now, settings), &MapSet.member?(asked, elem(&1, 0)))

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
        |> Enum.map(fn {id, vm} -> {id, :pressure, vm.memory_bytes} end)

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
        do: {id, :timer, vm.memory_bytes}
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
  are asked anyway. A guest's word counts for no more than its VM holds.
  Returns `{env_id, result, at}` for each VM asked.
  """
  def run_round(%{ask: ask, deficit: deficit}, keep_mb, reclaim, clock \\ &now/0) do
    {outcomes, _freed} =
      Enum.reduce(ask, {[], 0}, fn {id, reason, memory}, {outcomes, freed} ->
        if reason == :timer or freed < deficit do
          result = reclaim.(id, keep_mb)
          log(id, result)
          {[{id, result, clock.()} | outcomes], freed + counted(result, memory)}
        else
          {outcomes, freed}
        end
      end)

    Enum.reverse(outcomes)
  end

  defp counted({:ok, %{free_before_mb: before, free_after_mb: later}}, memory),
    do: min(max(later - before, 0) * @mib, memory)

  defp counted(_result, _memory), do: 0

  defp log(id, {:ok, r}) do
    Logger.info(
      "reclaimed #{id}'s page cache: #{r.file_before_mb} to #{r.file_after_mb} MiB, " <>
        "#{max(r.free_after_mb - r.free_before_mb, 0)} MiB freed in the guest " <>
        "(reclaim #{r.reclaim} in #{r.reclaim_ms} ms, compact #{r.compact} in #{r.compact_ms} ms)"
    )
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
  Takes a round's outcomes in at `now`: a VM that reclaimed settles, one
  that can't isn't asked again while it runs, and one that failed waits.
  After a round that reclaimed anything, nothing more is asked until the
  memory has had time to come back.
  """
  def record(state, outcomes, now) do
    vms =
      Enum.reduce(outcomes, state.vms, fn {id, result, at}, vms ->
        case vms do
          %{^id => vm} -> Map.put(vms, id, outcome(vm, result, at))
          _ -> vms
        end
      end)

    settle_until =
      if Enum.any?(outcomes, &match?({_, {:ok, _}, _}, &1)),
        do: now + @settle,
        else: state.settle_until

    %{state | vms: vms, settle_until: settle_until}
  end

  defp outcome(vm, {:ok, _}, at), do: %{vm | reclaimed_at: at, settled_bytes: nil, retry_at: nil}
  defp outcome(vm, {:error, :unsupported}, _at), do: %{vm | unsupported: true}
  defp outcome(vm, {:error, _}, at), do: %{vm | retry_at: at + @retry}

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

  @doc "Asks an environment's VM to reclaim its page cache past `keep_mb` (see `Link.reclaim/3`)."
  def reclaim(env_id, keep_mb, config),
    do: Link.reclaim(Links.get(env_id, config), keep_mb, @reclaim_timeout)

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

  def handle_info({:round_done, ref, outcomes}, %{round: {_pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | round: nil, policy: record(state.policy, outcomes, state.now.())}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{round: {_pid2, ref}} = state) do
    Logger.warning("a page cache reclaim round failed: #{inspect(reason)}")
    {:noreply, %{state | round: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

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

            send(server, {:round_done, ref, run_round(plan, keep_mb, reclaim, clock)})
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
