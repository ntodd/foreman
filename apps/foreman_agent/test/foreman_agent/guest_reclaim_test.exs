defmodule ForemanAgent.GuestReclaimTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Guest.Reclaim

  setup do
    # Unix socket paths are short on macOS; System.tmp_dir/0 is long there.
    dir = Path.join("/tmp", "fmr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "proc"))
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, proc: Path.join(dir, "proc"), helper: Path.join(dir, "r.sock")}
  end

  defp meminfo(ctx, free_kb, active_kb, inactive_kb) do
    File.write!(Path.join(ctx.proc, "meminfo"), """
    MemTotal:       32765000 kB
    MemFree:        #{free_kb} kB
    MemAvailable:   20000000 kB
    Active(file):   #{active_kb} kB
    Inactive(file): #{inactive_kb} kB
    """)
  end

  # A stand-in for the root helper: it reads the request to EOF, tells
  # the test, runs `act` (which can change meminfo, or wait), and answers.
  defp start_helper(ctx, answer, act \\ fn -> :ok end) do
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, ctx.helper},
        active: false,
        packet: :raw,
        # It answers after reading to the end of the request.
        exit_on_close: false
      ])

    pid =
      spawn_link(fn ->
        serve = fn serve ->
          {:ok, socket} = :gen_tcp.accept(listen)
          send(test, {:helper_request, read_all(socket, "")})
          act.()
          :gen_tcp.send(socket, answer)
          :gen_tcp.close(socket)
          serve.(serve)
        end

        serve.(serve)
      end)

    on_exit(fn -> :gen_tcp.close(listen) end)
    pid
  end

  defp read_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp run(ctx, args, opts \\ []),
    do: Reclaim.run(args, [proc: ctx.proc, helper: ctx.helper] ++ opts)

  test "asks for the page cache past what to keep, and reports what changed", ctx do
    meminfo(ctx, 1_000_000, 3_000_000, 6_000_000)

    start_helper(ctx, "ok reclaim=partial compact=ok reclaim_ms=950 compact_ms=480\n", fn ->
      meminfo(ctx, 8_000_000, 1_500_000, 500_000)
    end)

    assert {:ok, result} = run(ctx, %{"keep_mb" => 2048})

    # 9,000,000 kB of file LRU less 2 GiB.
    assert_received {:helper_request, "7068516352\n"}

    assert result == %{
             "requested_mb" => 6741,
             "file_before_mb" => 8789,
             "file_after_mb" => 1953,
             "free_before_mb" => 976,
             "free_after_mb" => 7812,
             "reclaim" => "partial",
             "compact" => "ok",
             "reclaim_ms" => 950,
             "compact_ms" => 480
           }
  end

  test "leaves a guest with little cache past what to keep alone", ctx do
    meminfo(ctx, 1_000_000, 1_000_000, 1_100_000)

    # 2,100,000 kB is 2050 MiB: 2 MiB past what to keep.
    assert {:ok, %{"reclaim" => "skipped", "compact" => "skipped", "requested_mb" => 0}} =
             run(ctx, %{"keep_mb" => 2048})

    refute_received {:helper_request, _}
  end

  test "a VM whose system image has no helper says it can't", ctx do
    meminfo(ctx, 1_000_000, 3_000_000, 6_000_000)
    assert {:error, message} = run(ctx, %{"keep_mb" => 0})
    assert message == Reclaim.unsupported()
  end

  test "a helper that refuses, or answers something else, is an error", ctx do
    meminfo(ctx, 1_000_000, 3_000_000, 6_000_000)
    start_helper(ctx, "error bad request\n")
    assert {:error, "the reclaim helper refused: bad request"} = run(ctx, %{"keep_mb" => 0})

    other = %{ctx | helper: Path.join(ctx.dir, "o.sock")}
    start_helper(other, "ok reclaim=maybe\n")

    assert {:error, "the reclaim helper answered something else"} =
             run(other, %{"keep_mb" => 0})
  end

  test "a helper that doesn't answer in time is an error", ctx do
    meminfo(ctx, 1_000_000, 3_000_000, 6_000_000)
    start_helper(ctx, "ok\n", fn -> Process.sleep(1_000) end)

    assert {:error, "the reclaim helper didn't answer in time"} =
             run(ctx, %{"keep_mb" => 0}, timeout: 100)
  end

  test "runs one at a time", ctx do
    meminfo(ctx, 1_000_000, 3_000_000, 6_000_000)
    test = self()

    start_helper(ctx, "ok reclaim=ok compact=ok reclaim_ms=1 compact_ms=1\n", fn ->
      send(test, {:helper_waiting, self()})

      receive do
        :answer -> :ok
      end
    end)

    first = Task.async(fn -> run(ctx, %{"keep_mb" => 0}) end)
    assert_receive {:helper_waiting, helper}, 5_000

    assert {:error, "a reclaim is already running"} = run(ctx, %{"keep_mb" => 0})

    send(helper, :answer)
    assert {:ok, %{"reclaim" => "ok"}} = Task.await(first)

    # And the next can run.
    send(helper, :answer)
    assert {:ok, _} = run(ctx, %{"keep_mb" => 0})
  end

  test "what to keep has to be a sensible number of MiB", ctx do
    meminfo(ctx, 1_000_000, 3_000_000, 6_000_000)

    for args <- [
          %{},
          %{"keep_mb" => -1},
          %{"keep_mb" => "2048"},
          %{"keep_mb" => 2.5},
          %{"keep_mb" => 1_048_577}
        ] do
      assert {:error, "keep_mb must be a whole number of MiB up to 1048576"} = run(ctx, args)
    end
  end

  test "a guest whose meminfo can't be read says so", ctx do
    assert {:error, "couldn't read the guest's memory: " <> _} = run(ctx, %{"keep_mb" => 0})
  end
end
