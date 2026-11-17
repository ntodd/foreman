defmodule ForemanAgent.VMReclaimerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForemanAgent.VM.Reclaimer

  @gib 1_073_741_824
  @total 128 * @gib
  @settings %{below: 20, keep_mb: 2048, idle_minutes: nil}
  @minute 60_000
  @tick 30_000

  # A VM's line in a sample: the CPU it has used (seconds) and its memory (GiB).
  defp vm(cpu_s, memory_gib),
    do: %{cpu_usec: round(cpu_s * 1_000_000), memory_bytes: round(memory_gib * @gib)}

  defp sample(available_gib, vms),
    do: %{available_bytes: round(available_gib * @gib), total_bytes: @total, vms: vms}

  # Samples every 30 s from `from` for `minutes`, each VM using `busy`
  # (fraction of a core) since its last sample and holding `memory` GiB:
  # %{id => {busy, memory}}. Returns the state and the last sample's time.
  defp run_for(state, from, minutes, vms, available_gib \\ 60) do
    ticks = div(minutes * @minute, @tick)

    Enum.reduce(0..ticks, {state, from}, fn i, {state, _} ->
      now = from + i * @tick

      line =
        Map.new(vms, fn {id, {busy, memory}} ->
          cpu =
            case state.vms[id] do
              %{cpu_usec: usec, seen_at: seen} -> usec + round(busy * (now - seen) * 1000)
              nil -> 0
            end

          {id, %{cpu_usec: cpu, memory_bytes: round(memory * @gib)}}
        end)

      {Reclaimer.observe(state, sample(available_gib, line), now), now}
    end)
  end

  defp current(state, available_gib) do
    vms =
      Map.new(state.vms, fn {id, e} ->
        {id, %{cpu_usec: e.cpu_usec, memory_bytes: e.memory_bytes}}
      end)

    sample(available_gib, vms)
  end

  defp asks(nil), do: []
  defp asks(%{ask: ask}), do: Enum.map(ask, & &1.id)

  # An outcome for the VM as the state knows it now.
  defp done(state, id, result, at),
    do: {%{id: id, incarnation: state.vms[id].incarnation}, result, at}

  defp item(id, reason, memory_gib), do: %{id: id, reason: reason, memory: memory_gib * @gib}

  test "nothing is asked while the box has room" do
    {state, now} = run_for(Reclaimer.new(), 0, 30, %{"a" => {0.01, 14}, "b" => {0.01, 10}})
    assert Reclaimer.plan(state, current(state, 40), now, @settings) == nil
  end

  test "under pressure, quiet VMs are asked longest quiet first, then biggest" do
    # a has been quiet for 30 minutes; b, c and d for 20; e for 5; f is busy.
    {state, t} =
      run_for(Reclaimer.new(), 0, 10, %{
        "a" => {0.02, 10},
        "b" => {0.8, 14},
        "c" => {0.8, 8},
        "d" => {0.8, 2.3}
      })

    {state, t} =
      run_for(state, t + @tick, 15, %{
        "a" => {0.02, 10},
        "b" => {0.02, 14},
        "c" => {0.02, 8},
        "d" => {0.02, 2.3},
        "e" => {0.6, 12},
        "f" => {0.6, 20}
      })

    {state, t} =
      run_for(state, t + @tick, 5, %{
        "a" => {0.02, 10},
        "b" => {0.02, 14},
        "c" => {0.02, 8},
        "d" => {0.02, 2.3},
        "e" => {0.02, 12},
        "f" => {0.9, 20}
      })

    plan = Reclaimer.plan(state, current(state, 20), t, @settings)

    # d holds too little past what it would keep to be worth asking.
    assert asks(plan) == ["a", "b", "c"]
    # Up to 25% of the box available.
    assert plan.deficit == 32 * @gib - 20 * @gib
    assert Enum.all?(plan.ask, &(&1.reason == :pressure))
  end

  test "a VM busy for one sample in the last ten minutes isn't quiet" do
    {state, t} = run_for(Reclaimer.new(), 0, 20, %{"a" => {0.02, 10}})
    {state, t} = run_for(state, t + @tick, 0, %{"a" => {0.6, 10}})
    {state, t} = run_for(state, t + @tick, 9, %{"a" => {0.02, 10}})
    assert Reclaimer.plan(state, current(state, 20), t, @settings) == nil

    {state, t} = run_for(state, t + @tick, 1, %{"a" => {0.02, 10}})
    assert asks(Reclaimer.plan(state, current(state, 20), t, @settings)) == ["a"]
  end

  test "a VM kept at a third of a core by healthchecks is quiet, and asked under pressure" do
    # #200's compose stack, each container healthchecked every second,
    # with the box seeing every vCPU wake for each check.
    {state, t} = run_for(Reclaimer.new(), 0, 9, %{"a" => {0.3, 10}})
    assert Reclaimer.plan(state, current(state, 20), t, @settings) == nil

    {state, t} = run_for(state, t + @tick, 1, %{"a" => {0.3, 10}})
    assert asks(Reclaimer.plan(state, current(state, 20), t, @settings)) == ["a"]
  end

  test "after a round, the box waits for the memory to come back before asking more" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    state = Reclaimer.record(state, [done(state, "a", {:ok, reclaimed(4096)}, t)], t)

    {state, t2} = run_for(state, t + @tick, 0, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    assert Reclaimer.plan(state, current(state, 20), t2, @settings) == nil

    {state, t3} = run_for(state, t2 + @tick, 1, %{"a" => {0.01, 6}, "b" => {0.01, 9}})
    assert asks(Reclaimer.plan(state, current(state, 20), t3, @settings)) == ["b"]
  end

  test "a reclaim whose drain failed is still a reclaim, and is waited on" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    drain_failed = %{reclaimed(4096) | drain: "failed"}
    state = Reclaimer.record(state, [done(state, "a", {:ok, drain_failed}, t)], t)

    {state, t2} = run_for(state, t + @tick, 0, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    assert Reclaimer.plan(state, current(state, 20), t2, @settings) == nil

    {state, t3} = run_for(state, t2 + @tick, 1, %{"a" => {0.01, 6}, "b" => {0.01, 9}})
    assert asks(Reclaimer.plan(state, current(state, 20), t3, @settings)) == ["b"]
  end

  test "a VM is asked again once it grows a GiB past where it settled, or after an hour" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    state = Reclaimer.record(state, [done(state, "a", {:ok, reclaimed(4096)}, t)], t)

    # It settles at 6 GiB.
    {state, t} = run_for(state, t + @tick, 3, %{"a" => {0.01, 6}})
    {state, t} = run_for(state, t + @tick, 5, %{"a" => {0.01, 6.9}})
    assert Reclaimer.plan(state, current(state, 20), t, @settings) == nil

    {state, t} = run_for(state, t + @tick, 0, %{"a" => {0.01, 7.1}})
    assert asks(Reclaimer.plan(state, current(state, 20), t, @settings)) == ["a"]

    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    state = Reclaimer.record(state, [done(state, "a", {:ok, reclaimed(4096)}, t)], t)
    {state, t} = run_for(state, t + @tick, 50, %{"a" => {0.01, 6}})
    assert Reclaimer.plan(state, current(state, 20), t, @settings) == nil
    {state, t} = run_for(state, t + @tick, 10, %{"a" => {0.01, 6}})
    assert asks(Reclaimer.plan(state, current(state, 20), t, @settings)) == ["a"]
  end

  test "a guest that can't reclaim isn't asked again until its VM starts again" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    state = Reclaimer.record(state, [done(state, "a", {:error, :unsupported}, t)], t)
    {state, t} = run_for(state, t + @tick, 120, %{"a" => {0.01, 10}})
    assert Reclaimer.plan(state, current(state, 20), t, @settings) == nil

    # Stopped, then started again.
    state = Reclaimer.observe(state, sample(60, %{}), t + @tick)
    {state, t} = run_for(state, t + 2 * @tick, 11, %{"a" => {0.01, 10}})
    assert asks(Reclaimer.plan(state, current(state, 20), t, @settings)) == ["a"]
  end

  test "a reclaim that fails is tried again ten minutes later" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    error = {:error, "the environment's VM didn't answer"}
    state = Reclaimer.record(state, [done(state, "a", error, t)], t)
    {state, t2} = run_for(state, t + @tick, 9, %{"a" => {0.01, 10}})
    assert Reclaimer.plan(state, current(state, 20), t2, @settings) == nil
    {state, t3} = run_for(state, t2 + @tick, 1, %{"a" => {0.01, 10}})
    assert asks(Reclaimer.plan(state, current(state, 20), t3, @settings)) == ["a"]
  end

  test "a VM that restarted between samples starts over" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    # Its cgroup's CPU counter went back to zero.
    state = Reclaimer.observe(state, sample(20, %{"a" => vm(1, 3)}), t + @tick)
    assert Reclaimer.plan(state, current(state, 20), t + @tick, @settings) == nil
  end

  test "the idle timer asks a VM once per quiet stretch, with or without pressure" do
    settings = %{@settings | idle_minutes: 60}
    {state, t} = run_for(Reclaimer.new(), 0, 59, %{"a" => {0.01, 10}, "b" => {0.8, 10}})
    assert Reclaimer.plan(state, current(state, 60), t, settings) == nil

    {state, t} = run_for(state, t + @tick, 1, %{"a" => {0.01, 10}, "b" => {0.8, 10}})

    assert %{ask: [%{id: "a", reason: :timer}]} =
             Reclaimer.plan(state, current(state, 60), t, settings)

    state = Reclaimer.record(state, [done(state, "a", {:ok, reclaimed(4096)}, t)], t)
    {state, t} = run_for(state, t + @tick, 120, %{"a" => {0.01, 6}, "b" => {0.8, 10}})
    assert Reclaimer.plan(state, current(state, 60), t, settings) == nil

    # Busy, then quiet for another hour.
    {state, t} = run_for(state, t + @tick, 0, %{"a" => {0.8, 9}, "b" => {0.8, 10}})
    {state, t} = run_for(state, t + @tick, 60, %{"a" => {0.01, 9}, "b" => {0.8, 10}})

    assert %{ask: [%{id: "a", reason: :timer}]} =
             Reclaimer.plan(state, current(state, 60), t, settings)
  end

  test "a reclaim whose writes failed in the guest is tried again ten minutes later" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    failed = %{reclaimed(0) | reclaim: "failed", compact: "failed"}
    state = Reclaimer.record(state, [done(state, "a", {:ok, failed}, t)], t)

    # Nothing came back, so there's nothing to wait for.
    {state, t2} = run_for(state, t + @tick, 0, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    assert asks(Reclaimer.plan(state, current(state, 20), t2, @settings)) == ["b"]

    {state, t3} = run_for(state, t2 + @tick, 10, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    assert asks(Reclaimer.plan(state, current(state, 20), t3, @settings)) == ["a", "b"]
  end

  test "a failed reclaim doesn't use up the idle timer's one ask" do
    settings = %{@settings | idle_minutes: 60}
    {state, t} = run_for(Reclaimer.new(), 0, 61, %{"a" => {0.01, 10}})
    failed = %{reclaimed(0) | reclaim: "failed"}
    state = Reclaimer.record(state, [done(state, "a", {:ok, failed}, t)], t)
    {state, t} = run_for(state, t + @tick, 10, %{"a" => {0.01, 10}})

    assert %{ask: [%{id: "a", reason: :timer}]} =
             Reclaimer.plan(state, current(state, 60), t, settings)
  end

  test "a guest with little cache past what it keeps isn't waited on, or asked again" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    skipped = %{reclaimed(0) | reclaim: "skipped", compact: "skipped", requested_mb: 0}
    state = Reclaimer.record(state, [done(state, "a", {:ok, skipped}, t)], t)

    {state, t2} = run_for(state, t + @tick, 0, %{"a" => {0.01, 10}, "b" => {0.01, 9}})
    assert asks(Reclaimer.plan(state, current(state, 20), t2, @settings)) == ["b"]
  end

  test "an outcome for a VM that has started again since it was asked is dropped" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    stale = done(state, "a", {:error, :unsupported}, t)

    # Stopped and started again before the outcome is recorded.
    state = Reclaimer.observe(state, sample(60, %{}), t + @tick)
    {state, t} = run_for(state, t + 2 * @tick, 11, %{"a" => {0.01, 10}})
    state = Reclaimer.record(state, [stale], t)
    assert asks(Reclaimer.plan(state, current(state, 20), t, @settings)) == ["a"]
  end

  test "a VM planned for is still askable while it stays quiet, and not after" do
    {state, t} = run_for(Reclaimer.new(), 0, 15, %{"a" => {0.01, 10}})
    [item] = Reclaimer.plan(state, current(state, 20), t, @settings).ask
    assert Reclaimer.still?(state, item)

    {state, _} = run_for(state, t + @tick, 0, %{"a" => {0.01, 10}})
    assert Reclaimer.still?(state, item)

    {busy, _} = run_for(state, t + 2 * @tick, 0, %{"a" => {0.7, 10}})
    refute Reclaimer.still?(busy, item)

    gone = Reclaimer.observe(state, sample(60, %{}), t + 2 * @tick)
    refute Reclaimer.still?(gone, item)
  end

  test "a box set to 0% never reclaims for pressure" do
    {state, t} = run_for(Reclaimer.new(), 0, 30, %{"a" => {0.01, 10}})
    assert Reclaimer.plan(state, current(state, 1), t, %{@settings | below: 0}) == nil
  end

  test "settings out of range are pulled in" do
    config = %ForemanAgent.Config{
      vm_reclaim_below: 200,
      vm_reclaim_keep_mb: -1,
      vm_reclaim_idle_minutes: 0
    }

    assert Reclaimer.settings(config) == %{below: 95, keep_mb: 0, idle_minutes: nil}

    config = %{
      config
      | vm_reclaim_below: -5,
        vm_reclaim_keep_mb: 1024,
        vm_reclaim_idle_minutes: 90
    }

    assert Reclaimer.settings(config) == %{below: 0, keep_mb: 1024, idle_minutes: 90}

    assert Reclaimer.settings(%ForemanAgent.Config{}) == %{
             below: 20,
             keep_mb: 2048,
             idle_minutes: nil
           }
  end

  describe "run_round/4" do
    defp freeing(by) do
      test = self()

      fn env_id, keep_mb ->
        send(test, {:asked, env_id, keep_mb})
        {:ok, reclaimed(Map.fetch!(by, env_id))}
      end
    end

    test "asks until what the guests freed covers the gap" do
      plan = %{
        ask: [
          item("a", :pressure, 10),
          item("b", :pressure, 10),
          item("c", :pressure, 10)
        ],
        deficit: 6 * @gib
      }

      outcomes =
        Reclaimer.run_round(plan, 2048, freeing(%{"a" => 4096, "b" => 4096, "c" => 4096}))

      assert [{%{id: "a"}, {:ok, _}, _}, {%{id: "b"}, {:ok, _}, _}] = outcomes
      assert_received {:asked, "a", 2048}
      assert_received {:asked, "b", 2048}
      refute_received {:asked, "c", _}
    end

    test "timer VMs are asked whatever the gap" do
      plan = %{ask: [item("a", :pressure, 10), item("b", :timer, 10)], deficit: 1}
      outcomes = Reclaimer.run_round(plan, 2048, freeing(%{"a" => 4096, "b" => 4096}))
      assert length(outcomes) == 2
    end

    test "a guest's numbers count for no more than its VM holds" do
      plan = %{ask: [item("a", :pressure, 3), item("b", :pressure, 10)], deficit: 6 * @gib}
      outcomes = Reclaimer.run_round(plan, 2048, freeing(%{"a" => 1_048_576, "b" => 4096}))
      assert [{%{id: "a"}, _, _}, {%{id: "b"}, _, _}] = outcomes
    end

    test "errors are kept, and the round goes on" do
      plan = %{ask: [item("a", :pressure, 10), item("b", :pressure, 10)], deficit: 6 * @gib}

      reclaim = fn
        "a", _ -> {:error, "the environment's VM didn't answer"}
        "b", _ -> {:ok, reclaimed(8192)}
      end

      log =
        capture_log(fn ->
          assert [{%{id: "a"}, {:error, _}, _}, {%{id: "b"}, {:ok, _}, _}] =
                   Reclaimer.run_round(plan, 2048, reclaim)
        end)

      assert log =~ "couldn't reclaim a's page cache: the environment's VM didn't answer"
    end

    test "a guest whose writes failed counts for nothing, and is warned about" do
      plan = %{ask: [item("a", :pressure, 10), item("b", :pressure, 10)], deficit: 6 * @gib}
      failed = %{reclaimed(8192) | reclaim: "failed", compact: "failed", drain: "failed"}

      reclaim = fn
        "a", _ -> {:ok, failed}
        "b", _ -> {:ok, reclaimed(8192)}
      end

      log = capture_log(fn -> assert [_, _] = Reclaimer.run_round(plan, 2048, reclaim) end)

      assert log =~
               "couldn't reclaim a's page cache: the guest's writes failed " <>
                 "(reclaim failed, compact failed, drain failed)"
    end

    test "a guest whose drain failed still counts, and is warned about" do
      plan = %{ask: [item("a", :pressure, 10), item("b", :pressure, 10)], deficit: 6 * @gib}
      drain_failed = %{reclaimed(8192) | drain: "failed", drain_ms: 3}

      reclaim = fn
        "a", _ -> {:ok, drain_failed}
        "b", _ -> {:ok, reclaimed(8192)}
      end

      # The test logger drops info, so only a warning is captured.
      log =
        capture_log(fn ->
          assert [{%{id: "a"}, {:ok, _}, _}] = Reclaimer.run_round(plan, 2048, reclaim)
        end)

      assert log =~ "reclaimed a's page cache: 10240 to 2048 MiB, 8192 MiB freed in the guest"
      assert log =~ "drain failed in 3 ms"
      assert log =~ "the guest couldn't drain its per-CPU free lists"
    end

    test "a reclaim that drained says so, and isn't a warning" do
      plan = %{ask: [item("a", :pressure, 10)], deficit: 6 * @gib}
      reclaim = fn "a", _ -> {:ok, reclaimed(8192)} end

      assert capture_log(fn -> Reclaimer.run_round(plan, 2048, reclaim) end) == ""

      # Only this module's tests log from the Reclaimer, one at a time.
      log =
        try do
          Logger.put_module_level(Reclaimer, :info)
          capture_log([level: :info], fn -> Reclaimer.run_round(plan, 2048, reclaim) end)
        after
          Logger.delete_module_level(Reclaimer)
        end

      assert log =~ "[info] reclaimed a's page cache"
      assert log =~ "(reclaim ok in 900 ms, compact ok in 400 ms, drain ok in 30 ms)"
    end

    test "only VMs still allowed are asked, and each outcome is reported as it comes" do
      test = self()

      plan = %{
        ask: [item("a", :pressure, 10), item("b", :pressure, 10), item("c", :pressure, 10)],
        deficit: 100 * @gib
      }

      outcomes =
        Reclaimer.run_round(plan, 2048, freeing(%{"a" => 1024, "c" => 1024}),
          allowed?: &(&1.id != "b"),
          report: &send(test, {:reported, elem(&1, 0).id})
        )

      assert [{%{id: "a"}, _, _}, {%{id: "c"}, _, _}] = outcomes
      refute_received {:asked, "b", _}
      assert_received {:reported, "a"}
      assert_received {:reported, "c"}
    end
  end

  describe "the server" do
    test "samples, and asks the quiet VMs when the box runs short" do
      test = self()
      clock = :counters.new(1, [])
      available = :atomics.new(1, [])
      :atomics.put(available, 1, 60)

      sampler = fn ->
        now = :counters.get(clock, 1)
        cpu = div(now, 1000) * 10_000

        {:ok,
         sample(:atomics.get(available, 1), %{"a" => %{cpu_usec: cpu, memory_bytes: 12 * @gib}})}
      end

      reclaim = fn env_id, keep_mb ->
        send(test, {:asked, env_id, keep_mb})
        {:ok, reclaimed(8192)}
      end

      pid =
        start_supervised!(
          {Reclaimer,
           name: nil,
           every: :manual,
           sample: sampler,
           reclaim: reclaim,
           now: fn -> :counters.get(clock, 1) end,
           settings: @settings}
        )

      tick = fn ->
        :counters.add(clock, 1, @tick)
        send(pid, :tick)
        :sys.get_state(pid)
      end

      for _ <- 1..25, do: tick.()
      refute_received {:asked, _, _}

      :atomics.put(available, 1, 20)

      capture_log(fn ->
        tick.()
        assert_receive {:asked, "a", 2048}, 5_000
        # The round finished.
        Process.sleep(50)
        :sys.get_state(pid)
      end)
    end
  end

  describe "the server, mid-round" do
    test "a VM that gets busy while an earlier guest takes its time isn't asked" do
      test = self()
      clock = :counters.new(1, [])
      busy_b = :atomics.new(1, [])
      available = :atomics.new(1, [])
      :atomics.put(available, 1, 60)

      sampler = fn ->
        now = :counters.get(clock, 1)
        quiet = div(now, 1000) * 10_000
        b = quiet + :atomics.get(busy_b, 1)

        {:ok,
         sample(:atomics.get(available, 1), %{
           "a" => %{cpu_usec: quiet, memory_bytes: 12 * @gib},
           "b" => %{cpu_usec: b, memory_bytes: 10 * @gib}
         })}
      end

      reclaim = fn
        "a", _ ->
          send(test, {:asked, "a", self()})

          receive do
            :answer -> {:ok, reclaimed(512)}
          end

        id, _ ->
          send(test, {:asked, id, self()})
          {:ok, reclaimed(512)}
      end

      pid =
        start_supervised!(
          {Reclaimer,
           name: nil,
           every: :manual,
           sample: sampler,
           reclaim: reclaim,
           now: fn -> :counters.get(clock, 1) end,
           settings: @settings}
        )

      tick = fn ->
        :counters.add(clock, 1, @tick)
        send(pid, :tick)
        :sys.get_state(pid)
      end

      for _ <- 1..25, do: tick.()
      :atomics.put(available, 1, 20)

      capture_log(fn ->
        tick.()
        assert_receive {:asked, "a", guest}, 5_000

        # b runs a build: 20 s of CPU in the next 30.
        :atomics.put(busy_b, 1, 20_000_000)
        tick.()

        send(guest, :answer)
        refute_receive {:asked, "b", _}, 500
        assert :sys.get_state(pid).round == nil
      end)
    end
  end

  defp reclaimed(freed_mb) do
    %{
      requested_mb: freed_mb,
      file_before_mb: freed_mb + 2048,
      file_after_mb: 2048,
      free_before_mb: 500,
      free_after_mb: 500 + freed_mb,
      reclaim: "ok",
      compact: "ok",
      drain: "ok",
      reclaim_ms: 900,
      compact_ms: 400,
      drain_ms: 30
    }
  end
end
