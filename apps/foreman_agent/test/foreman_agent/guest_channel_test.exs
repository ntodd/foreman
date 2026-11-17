defmodule ForemanAgent.GuestChannelTest do
  # The host's link to a real guest agent (Guest.Server, Ops and Outbox)
  # through a stand-in for Cloud Hypervisor's hybrid vsock.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForemanAgent.{Channel, Ops, Outbox}
  alias ForemanAgent.Guest.Server
  alias ForemanAgent.Test.VsockBridge
  alias ForemanAgent.VM.Link
  alias ForemanProtocol.{Command, Schema}

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup do
    # Unix socket paths are short on macOS; System.tmp_dir/0 is long there.
    dir = Path.join("/tmp", "fmg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, guest: Path.join(dir, "g.sock"), vsock: Path.join(dir, "v.sock")}
  end

  # A guest agent whose operations report to the test and wait to be
  # released, like ForemanAgent.OpsTest's.
  defp start_guest(ctx, extra \\ []) do
    agent = start_guest_agent(ctx, extra)
    bridge = start_supervised!({VsockBridge, path: ctx.vsock, target: ctx.guest}, id: :bridge)
    Map.put(agent, :bridge, bridge)
  end

  defp start_guest_agent(ctx, extra \\ []) do
    test = self()

    handler = fn cmd, log ->
      log.("stdout", "running #{cmd.type}\n")
      send(test, {:started, cmd.op_id, self()})

      receive do
        {:finish, result} -> result
      end
    end

    # Named, so the Outbox a supervisor starts again is the one Ops and
    # the session use.
    outbox = :"outbox-#{System.unique_integer([:positive])}"
    start_supervised!({Outbox, name: outbox}, id: :outbox)

    ops = :"ops-#{System.unique_integer([:positive])}"

    start_supervised!(
      {Ops, name: ops, handler: handler, sink: &Outbox.push(outbox, &1)},
      id: :ops
    )

    session =
      [
        ops: ops,
        outbox: outbox,
        clock: fn now -> send(test, {:clock, now}) end,
        configure: fn config -> send(test, {:configured, config}) end,
        queries: %{"inventory" => fn -> {:ok, [%{"env_id" => @env}]} end}
      ]
      |> Keyword.merge(extra)

    start_supervised!({Server, name: nil, path: ctx.guest, session: session}, id: :server)
    %{ops: ops, outbox: outbox}
  end

  defp start_link(ctx, opts \\ []) do
    start_supervised!(
      {Link, [socket: ctx.vsock, config: %{"allowed_git_hosts" => ["github.com"]}] ++ opts},
      id: :link
    )
  end

  defp command(type \\ "env.stop") do
    {:ok, cmd} = Command.new(type, %{env_id: @env, slug: "hello-1"})
    cmd
  end

  defp secrets(files) do
    {:ok, cmd} = Command.new("env.secrets.write", %{env_id: @env, files: files})
    cmd
  end

  defp run_async(link, cmd, opts \\ []) do
    test = self()

    spawn(fn ->
      log = fn stream, data -> send(test, {:log, stream, data}) end
      send(test, {:result, Link.run(link, cmd, log, opts)})
    end)
  end

  test "runs a command in the guest and passes its logs on", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)

    assert_receive {:started, ^op_id, pid}, 5_000
    assert_receive {:log, "stdout", "running env.stop\n"}, 5_000
    send(pid, {:finish, {:ok, %{"stopped" => true}}})
    assert_receive {:result, {:ok, %{"stopped" => true}}}, 5_000
  end

  test "an error keeps the result that came with it", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)

    assert_receive {:started, ^op_id, pid}, 5_000
    send(pid, {:finish, {:error, "refused", %{"pulled" => false}}})
    assert_receive {:result, {:error, "refused", %{"pulled" => false}}}, 5_000
  end

  test "hello gives the guest the host's time and config", ctx do
    start_guest(ctx)
    start_link(ctx)

    assert_receive {:clock, now}, 5_000
    assert_in_delta now, Channel.now(), 5_000
    assert_receive {:configured, %{"allowed_git_hosts" => ["github.com"]}}, 5_000
  end

  test "a command survives a lost connection and runs once", ctx do
    %{bridge: bridge} = start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, pid}, 5_000

    # The link reconnects and sends the command again; the guest knows it.
    VsockBridge.drop(bridge)
    wait_until(fn -> Link.connected?(link) end)
    send(pid, {:finish, {:ok, %{"once" => true}}})

    assert_receive {:result, {:ok, %{"once" => true}}}, 5_000
    refute_receive {:started, ^op_id, _}, 300
  end

  test "a result that lands while the connection is down is delivered on reconnect", ctx do
    %{bridge: bridge} = start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, pid}, 5_000

    :sys.suspend(link)
    VsockBridge.drop(bridge)
    send(pid, {:finish, {:ok, %{"late" => true}}})
    Process.sleep(100)
    :sys.resume(link)

    assert_receive {:result, {:ok, %{"late" => true}}}, 5_000
  end

  test "a caller that goes away cancels its command in the guest", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id

    caller = spawn(fn -> Link.run(link, cmd, fn _, _ -> :ok end) end)
    assert_receive {:started, ^op_id, pid}, 5_000
    ref = Process.monitor(pid)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  test "a caller that goes away while the connection is down cancels once it's back", ctx do
    %{bridge: bridge} = start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id

    caller = spawn(fn -> Link.run(link, cmd, fn _, _ -> :ok end) end)
    assert_receive {:started, ^op_id, pid}, 5_000
    ref = Process.monitor(pid)

    # The link hears the connection close before the caller goes.
    :sys.suspend(link)
    VsockBridge.drop(bridge)
    Process.sleep(100)
    Process.exit(caller, :kill)
    Process.sleep(50)
    :sys.resume(link)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  test "an Outbox that restarts closes the connection, and the next attaches to the new one",
       ctx do
    %{outbox: outbox} = start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, pid}, 5_000
    assert_receive {:log, "stdout", "running env.stop\n"}, 5_000

    old = GenServer.whereis(outbox)
    Process.exit(old, :kill)
    wait_until(fn -> GenServer.whereis(outbox) not in [nil, old] end)

    # The result goes to the new Outbox, which the session has to be
    # attached to for it to reach the box.
    send(pid, {:finish, {:ok, %{"after" => true}}})
    assert_receive {:result, {:ok, %{"after" => true}}}, 5_000
  end

  # A new Ops knows nothing of what the old one ran: the session closes,
  # and the box hears of the new instance at the next hello.
  test "an Ops that restarts fails what it was running, rather than leaving it waiting", ctx do
    %{ops: ops} = start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, _pid}, 5_000

    old = GenServer.whereis(ops)
    Process.exit(old, :kill)

    assert_receive {:result, {:error, "the environment's VM restarted while running it"}}, 5_000
  end

  test "a command that runs past its timeout fails, and is cancelled in the guest", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd, timeout: 1_000)

    assert_receive {:started, ^op_id, pid}, 5_000
    ref = Process.monitor(pid)
    assert_receive {:result, {:error, "the environment's VM didn't finish it in time"}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  test "a timeout that isn't one is refused before it reaches the link", ctx do
    link = start_link(ctx)

    assert_raise ArgumentError, fn ->
      Link.run(link, command(), fn _, _ -> :ok end, timeout: -1)
    end

    assert Process.alive?(link)
  end

  test "a VM that restarts fails what it was running rather than running it again", ctx do
    %{bridge: bridge} = start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, _pid}, 5_000

    # A new guest agent, which knows nothing of the command.
    for id <- [:server, :ops, :outbox], do: :ok = stop_supervised(id)
    start_guest_agent(ctx)
    VsockBridge.drop(bridge)

    assert_receive {:result, {:error, "the environment's VM restarted while running it"}}, 5_000
    refute_receive {:started, ^op_id, _}, 300

    # The link carries on with the new one.
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, pid}, 5_000
    send(pid, {:finish, {:ok, %{"new" => true}}})
    assert_receive {:result, {:ok, %{"new" => true}}}, 5_000
  end

  test "the guest takes commands larger than anything it may send back", ctx do
    start_guest(ctx)
    link = start_link(ctx)

    files =
      Map.new(~w(secrets.env github-token gitconfig), &{&1, String.duplicate("a", 1_000_000)})

    cmd = secrets(files)
    op_id = cmd.op_id
    run_async(link, cmd)

    assert_receive {:started, ^op_id, pid}, 5_000
    send(pid, {:finish, {:ok, %{}}})
    assert_receive {:result, {:ok, %{}}}, 5_000
  end

  test "a command too large for the channel fails without being sent", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    wait_until(fn -> Link.connected?(link) end)
    cmd = secrets(Map.new(Schema.secret_files(), &{&1, String.duplicate("a", 900_000)}))
    run_async(link, cmd)

    assert_receive {:result,
                    {:error, "the command is too large to send to the environment's VM"}},
                   5_000
  end

  test "a result too large to send to the box comes back as an error", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)

    assert_receive {:started, ^op_id, pid}, 5_000
    send(pid, {:finish, {:ok, %{"big" => String.duplicate("a", 2_000_000)}}})
    assert_receive {:result, {:error, "the result was too large to send to the box"}}, 5_000
  end

  test "queries are answered", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    wait_until(fn -> Link.connected?(link) end)

    assert {:ok, [%{"env_id" => @env}]} = Link.query(link, "inventory")
    assert {:error, "unknown query"} = Link.query(link, "secrets")
  end

  test "a VM that stops fails the commands waiting on it", ctx do
    start_guest(ctx)
    alive = :atomics.new(1, [])
    :atomics.put(alive, 1, 1)
    link = start_link(ctx, alive?: fn -> :atomics.get(alive, 1) == 1 end)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, _pid}, 5_000

    :atomics.put(alive, 1, 0)
    :ok = stop_supervised(:bridge)

    assert_receive {:result, {:error, "the environment's VM isn't running"}}, 5_000
  end

  test "a link that's gone isn't connected", ctx do
    {:ok, link} = Link.start_link(socket: ctx.vsock)
    GenServer.stop(link)
    refute Link.connected?(link)
  end

  test "the guest refuses commands the box runs itself" do
    {:ok, cmd} = Command.new("box.restart", %{boot_id: @env})

    assert {:error, "box.restart isn't run in an environment's VM"} =
             ForemanAgent.Guest.handle(cmd, fn _, _ -> :ok end)
  end

  describe "Channel.decode/2" do
    test "decodes a frame" do
      assert {:ok, %{"t" => "hello", "n" => 1}} = Channel.decode(~s({"t":"hello","n":1}))
      assert {:error, :malformed} = Channel.decode(~s({"n":1}))
      assert {:error, :malformed} = Channel.decode("[")
    end

    test "a number too large to decode is malformed" do
      huge = ~s({"t":"event","seq":) <> String.duplicate("9", 2_000_000) <> "}"
      assert {:error, :malformed} = Channel.decode(huge)
    end

    test "a frame that costs too much heap to decode is malformed" do
      deep = String.duplicate("[", 400_000) <> String.duplicate("]", 400_000)
      assert {:error, :malformed} = Channel.decode(~s({"t":"event","x":#{deep}}))
    end

    test "a frame that takes too long to decode is malformed" do
      slow = ~s({"t":"event","x":) <> String.duplicate("9", 900_000) <> "}"
      assert {:error, :malformed} = Channel.decode(slow, timeout: 1)
    end

    test "a frame that's only big decodes" do
      big = String.duplicate("a", Channel.max_frame(:to_guest) - 100)
      assert {:ok, %{"data" => ^big}} = Channel.decode(~s({"t":"cmd","data":"#{big}"}))
    end

    test "a number that costs more heap than a legitimate frame needs is malformed" do
      # Decodes under a loose heap, not under the default: an honest frame
      # never carries a 400,000-digit number.
      frame = ~s({"t":"event","x":) <> String.duplicate("1", 400_000) <> "}"
      assert {:ok, _} = Channel.decode(frame, max_heap: 8 * 1024 * 1024)
      assert {:error, :malformed} = Channel.decode(frame)
    end
  end

  describe "a hostile guest" do
    # A fake VM: it answers Cloud Hypervisor's CONNECT itself, tells the
    # test about each connection, then hands it to `serve`.
    defp start_fake_vm(ctx, serve) do
      test = self()
      _ = File.rm(ctx.vsock)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, ctx.vsock}}, active: false, packet: :line])

      spawn(fn -> fake_accept(listen, test, serve) end)
      listen
    end

    defp fake_accept(listen, test, serve) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          pid = spawn(fn -> fake_connection(socket, test, serve) end)
          :ok = :gen_tcp.controlling_process(socket, pid)
          send(pid, :go)
          fake_accept(listen, test, serve)

        {:error, _} ->
          :ok
      end
    end

    defp fake_connection(socket, test, serve) do
      receive do
        :go -> :ok
      end

      with {:ok, "CONNECT 1024\n"} <- :gen_tcp.recv(socket, 0, 5_000),
           :ok <- :gen_tcp.send(socket, "OK 1024\n"),
           :ok <- :inet.setopts(socket, Channel.frame_opts(:guest)) do
        send(test, :vm_connected)
        serve.(socket)
      end
    end

    # Answers each frame the link sends with the script's replies. A reply
    # of `:close` hangs up.
    defp reactive(script) do
      test = self()
      fn socket -> react(socket, test, script) end
    end

    defp react(socket, test, script) do
      case :gen_tcp.recv(socket, 0) do
        {:ok, data} ->
          {:ok, frame} = Channel.decode(data)
          send(test, {:host_sent, frame})

          Enum.each(script.(frame), fn
            :close -> :gen_tcp.close(socket)
            reply -> :gen_tcp.send(socket, reply)
          end)

          react(socket, test, script)

        {:error, _} ->
          :ok
      end
    end

    defp hello(version \\ "0.1.0", instance \\ "fake-instance") do
      Channel.encode(%{"t" => "hello", "agent_version" => version, "instance" => instance})
    end

    defp event(type, payload, seq \\ nil) do
      {:ok, event} = ForemanProtocol.Event.new(type, payload)

      Channel.encode(%{
        "t" => "event",
        "seq" => seq,
        "event" => ForemanProtocol.Event.to_wire(event)
      })
    end

    defp reply(id, fields), do: Channel.encode(Map.merge(%{"t" => "reply", "id" => id}, fields))

    defp count_received(message, count \\ 0) do
      receive do
        ^message -> count_received(message, count + 1)
      after
        0 -> count
      end
    end

    defp ports(pid),
      do: Enum.count(Port.list(), &(Port.info(&1, :connected) == {:connected, pid}))

    # How many messages `pid` has waiting, once that stops growing.
    defp settled_queue(pid, last \\ -1, tries \\ 100) do
      Process.sleep(200)
      {:message_queue_len, queued} = Process.info(pid, :message_queue_len)

      cond do
        queued > 0 and queued == last -> queued
        tries == 0 -> flunk("the queue kept growing")
        true -> settled_queue(pid, queued, tries - 1)
      end
    end

    test "only the result for the command reaches the caller", ctx do
      other = ForemanProtocol.uuid()

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            [
              "not json",
              Channel.encode(%{"t" => "nonsense"}),
              Channel.encode(%{"no" => "type"}),
              Channel.encode(%{
                "t" => "event",
                "event" => %{"type" => "op.result", "payload" => %{}}
              }),
              Channel.encode(%{
                "t" => "event",
                "event" => %{"type" => "op.log", "payload" => "x"}
              }),
              event("op.log", %{op_id: other, stream: "stdout", data: "someone else's\n"}),
              event("op.result", %{op_id: other, status: "ok", result: %{"forged" => true}}, 1),
              event("box.inventory", %{environments: []}),
              event("op.log", %{op_id: op_id, stream: "stdout", data: "mine\n"}),
              event("op.result", %{op_id: op_id, status: "ok", result: %{"real" => true}}, 2)
            ]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      run_async(link, command())

      assert_receive {:result, {:ok, %{"real" => true}}}, 5_000
      assert_receive {:log, "stdout", "mine\n"}
      refute_received {:log, _, "someone else's\n"}
      # Results are acknowledged, so the guest doesn't send them forever.
      assert_receive {:host_sent, %{"t" => "ack", "seq" => 1}}, 5_000
      assert_receive {:host_sent, %{"t" => "ack", "seq" => 2}}, 5_000
    end

    test "results for commands the link didn't send are dropped, not kept", ctx do
      forged = ForemanProtocol.uuid()

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello(), event("op.result", %{op_id: forged, status: "ok", result: %{"x" => 1}}, 1)]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            [event("op.result", %{op_id: op_id, status: "ok", result: %{"real" => true}}, 2)]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      assert_receive {:host_sent, %{"t" => "ack", "seq" => 1}}, 5_000

      # The same op id, sent now, goes to the guest.
      run_async(link, %{command() | op_id: forged})
      assert_receive {:host_sent, %{"t" => "cmd", "cmd" => %{"op_id" => ^forged}}}, 5_000
      assert_receive {:result, {:ok, %{"real" => true}}}, 5_000
    end

    test "a guest that never says hello isn't connected, and gets nothing", ctx do
      start_fake_vm(ctx, reactive(fn _ -> [] end))
      link = start_link(ctx)
      cmd = command()
      op_id = cmd.op_id
      run_async(link, cmd)

      assert_receive {:host_sent, %{"t" => "hello"}}, 5_000
      refute Link.connected?(link)
      assert {:error, :not_connected} = Link.query(link, "inventory")
      refute_receive {:host_sent, %{"t" => "cmd", "cmd" => %{"op_id" => ^op_id}}}, 500
    end

    test "a hello repeated on the same connection doesn't send everything again", ctx do
      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} -> [hello()]
          %{"t" => "cmd"} -> [hello()]
          _ -> []
        end)
      )

      link = start_link(ctx)
      cmd = command()
      op_id = cmd.op_id
      run_async(link, cmd)

      assert_receive {:host_sent, %{"t" => "cmd", "cmd" => %{"op_id" => ^op_id}}}, 5_000
      refute_receive {:host_sent, %{"t" => "cmd"}}, 500
    end

    test "an oversized frame drops the connection, and the link reconnects", ctx do
      counter = :counters.new(1, [])

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            :counters.add(counter, 1, 1)

            # The guest's frames are at most 1 MiB (the host's are 4).
            if :counters.get(counter, 1) == 1,
              do: [:binary.copy("x", 1_048_577)],
              else: [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            [event("op.result", %{op_id: op_id, status: "ok", result: %{"after" => true}}, 1)]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      run_async(link, command())

      assert_receive {:result, {:ok, %{"after" => true}}}, 3_000
      assert :counters.get(counter, 1) >= 2
    end

    test "a flood of tiny frames is paced by the per-frame cost, not just bytes", ctx do
      # Frames far smaller than @frame_charge: without the per-frame
      # minimum they'd all fit the burst in bytes and be read at once,
      # keeping a host scheduler busy decoding them.
      test = self()
      total = 16

      frame = fn n ->
        Channel.encode(%{"t" => "event", "seq" => n, "event" => %{"type" => "noop"}})
      end

      start_fake_vm(ctx, fn socket ->
        {:ok, _hello} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, hello())
        Enum.each(1..total, fn n -> :gen_tcp.send(socket, frame.(n)) end)

        count = fn count ->
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, data} ->
              {:ok, %{"t" => "ack"}} = Channel.decode(data)
              send(test, :acked)
              count.(count)

            {:error, _} ->
              :ok
          end
        end

        count.(count)
      end)

      # Burst and rate in bytes, but the ~40-byte frames each cost the
      # 512-byte minimum: a ~4-frame burst, then a handful per second.
      start_link(ctx, read_burst: 2_048, read_rate: 5_000)
      assert_receive :vm_connected, 5_000

      Process.sleep(250)
      early = count_received(:acked)
      assert early < total, "read all #{total} tiny frames at once (#{early}); only bytes were charged"
      assert early <= 8

      got =
        Enum.reduce_while(1..60, early, fn _, acc ->
          acc = acc + count_received(:acked)

          if acc >= total do
            {:halt, acc}
          else
            Process.sleep(100)
            {:cont, acc}
          end
        end)

      assert got == total
    end

    test "the link reads the guest no faster than its rate allows", ctx do
      test = self()
      total = 16

      frame = fn n ->
        Channel.encode(%{
          "t" => "event",
          "seq" => n,
          "event" => %{"type" => "noop"},
          "pad" => String.duplicate("a", 4_000)
        })
      end

      start_fake_vm(ctx, fn socket ->
        {:ok, _hello} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, hello())
        # More frames at once than the burst covers.
        Enum.each(1..total, fn n -> :gen_tcp.send(socket, frame.(n)) end)

        # The link acks each event as it reads it, so the acks meter how
        # fast it's reading.
        count = fn count ->
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, data} ->
              {:ok, %{"t" => "ack"}} = Channel.decode(data)
              send(test, :acked)
              count.(count)

            {:error, _} ->
              :ok
          end
        end

        count.(count)
      end)

      # ~4 KB frames: a 2-frame burst, then ~10 frames/second.
      start_link(ctx, read_burst: 8_200, read_rate: 41_000)
      assert_receive :vm_connected, 5_000

      Process.sleep(250)
      early = count_received(:acked)
      assert early < total, "read all #{total} frames at once (#{early}); the rate limit didn't bite"
      assert early <= 6

      # The rest arrive as the bucket refills.
      got =
        Enum.reduce_while(1..60, early, fn _, acc ->
          acc = acc + count_received(:acked)

          if acc >= total do
            {:halt, acc}
          else
            Process.sleep(100)
            {:cont, acc}
          end
        end)

      assert got == total
    end

    test "a frame too large to decode doesn't take the link down", ctx do
      counter = :counters.new(1, [])
      huge = ~s({"t":"event","seq":) <> String.duplicate("9", 2_000_000) <> "}"

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            :counters.add(counter, 1, 1)
            if :counters.get(counter, 1) == 1, do: [hello(), huge], else: [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            [event("op.result", %{op_id: op_id, status: "ok", result: %{"after" => true}}, 1)]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      wait_until(fn -> Link.connected?(link) end)
      run_async(link, command())

      assert_receive {:result, {:ok, %{"after" => true}}}, 5_000
      assert Process.alive?(link)
    end

    test "the link reads no faster than its caller takes the log", ctx do
      chunk = String.duplicate("x", 65_536)

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            log = event("op.log", %{op_id: op_id, stream: "stdout", data: chunk})
            result = event("op.result", %{op_id: op_id, status: "ok", result: %{}}, 1)
            List.duplicate(log, 128) ++ [result]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      test = self()

      caller =
        spawn(fn ->
          # Stuck on the first chunk until the test says go.
          log = fn _stream, data ->
            if Process.get(:held, true) do
              receive do
                :go -> Process.put(:held, false)
              end
            end

            send(test, {:took, byte_size(data)})
          end

          send(test, {:result, Link.run(link, command(), log)})
        end)

      Process.sleep(1_000)
      {:message_queue_len, queued} = Process.info(caller, :message_queue_len)
      assert queued <= 20

      send(caller, :go)
      assert_receive {:result, {:ok, %{}}}, 10_000
      assert count_received({:took, 65_536}) == 128
    end

    test "a command's log past its budget is dropped, with a notice", ctx do
      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            logs =
              for i <- 1..5 do
                data = "#{i}" <> String.duplicate("x", 39)
                event("op.log", %{op_id: op_id, stream: "stdout", data: data})
              end

            logs ++ [event("op.result", %{op_id: op_id, status: "ok", result: %{}}, 1)]

          _ ->
            []
        end)
      )

      # Each 40-byte chunk counts for 104: two fit.
      link = start_link(ctx, log_budget: 250)
      run_async(link, command())

      assert_receive {:result, {:ok, %{}}}, 5_000
      assert_received {:log, "stdout", "1" <> _}
      assert_received {:log, "stdout", "2" <> _}

      assert_received {:log, "info",
                       "the VM sent more log than the box keeps; the rest is dropped\n"}

      refute_received {:log, _, _}
    end

    test "empty log chunks are dropped", ctx do
      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            empty = event("op.log", %{op_id: op_id, stream: "stdout", data: ""})

            List.duplicate(empty, 1_000) ++
              [
                event("op.log", %{op_id: op_id, stream: "stdout", data: "mine\n"}),
                event("op.result", %{op_id: op_id, status: "ok", result: %{}}, 1)
              ]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      run_async(link, command())

      assert_receive {:result, {:ok, %{}}}, 5_000
      assert_received {:log, "stdout", "mine\n"}
      refute_received {:log, _, ""}
    end

    test "a log chunk counts for more than its bytes against the budget", ctx do
      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            log = event("op.log", %{op_id: op_id, stream: "stdout", data: "x"})
            List.duplicate(log, 100) ++ [event("op.result", %{op_id: op_id, status: "ok"}, 1)]

          _ ->
            []
        end)
      )

      link = start_link(ctx, log_budget: 1_000)
      run_async(link, command())

      assert_receive {:result, {:ok, %{}}}, 5_000
      assert count_received({:log, "stdout", "x"}) <= 1_000 / 64

      assert_received {:log, "info",
                       "the VM sent more log than the box keeps; the rest is dropped\n"}
    end

    test "small log chunks count for more than their bytes against the window", ctx do
      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello()]

          %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
            log = event("op.log", %{op_id: op_id, stream: "stdout", data: "x"})
            List.duplicate(log, 30_000) ++ [event("op.result", %{op_id: op_id, status: "ok"}, 1)]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      test = self()

      caller =
        spawn(fn ->
          log = fn _stream, _data ->
            if Process.get(:held, true) do
              receive do
                :go -> Process.put(:held, false)
              end
            end
          end

          send(test, {:result, Link.run(link, command(), log)})
        end)

      # The caller takes nothing; the link reads until the window is full.
      queued = settled_queue(caller)
      assert queued <= div(1_048_576, 64) + 100

      send(caller, :go)
      assert_receive {:result, {:ok, %{}}}, 20_000
    end

    test "a cancel goes on every hello until the guest has a result for the command", ctx do
      hellos = :counters.new(1, [])

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            :counters.add(hellos, 1, 1)
            [hello()]

          %{"t" => "cancel", "op_id" => target} ->
            case :counters.get(hellos, 1) do
              # Only the result of the cancel itself (an op id of its
              # own), and the connection drops before the guest acts on it.
              1 -> [event("op.result", %{op_id: ForemanProtocol.uuid(), status: "ok"}, 1), :close]
              # The command finished first: its result settles the cancel.
              2 -> [event("op.result", %{op_id: target, status: "ok"}, 2), :close]
              _ -> []
            end

          _ ->
            []
        end)
      )

      link = start_link(ctx, retry: 20, max_retry: 50)
      cmd = command()
      op_id = cmd.op_id
      caller = spawn(fn -> Link.run(link, cmd, fn _, _ -> :ok end) end)
      assert_receive {:host_sent, %{"t" => "cmd", "cmd" => %{"op_id" => ^op_id}}}, 5_000
      Process.exit(caller, :kill)

      assert_receive {:host_sent, %{"t" => "cancel", "op_id" => ^op_id}}, 5_000
      assert_receive {:host_sent, %{"t" => "cancel", "op_id" => ^op_id}}, 5_000

      wait_until(fn -> :counters.get(hellos, 1) >= 3 end)
      refute_receive {:host_sent, %{"t" => "cancel"}}, 500
    end

    test "the cancels kept for the guest are bounded, oldest dropped first", ctx do
      # Nothing listens yet, so every command waits and every cancel is kept.
      link = start_link(ctx, retry: 20, max_retry: 50)

      run = fn cmds ->
        for cmd <- cmds, do: spawn(fn -> Link.run(link, cmd, fn _, _ -> :ok end) end)
      end

      oldest = for _ <- 1..44, do: command()
      newest = for _ <- 1..256, do: command()
      oldest_callers = run.(oldest)
      newest_callers = run.(newest)
      wait_until(fn -> map_size(:sys.get_state(link).pending) == 300 end)

      Enum.each(oldest_callers, &Process.exit(&1, :kill))
      wait_until(fn -> map_size(:sys.get_state(link).pending) == 256 end)

      log =
        capture_log(fn ->
          Enum.each(newest_callers, &Process.exit(&1, :kill))
          wait_until(fn -> :sys.get_state(link).pending == %{} end)
        end)

      assert log =~ "cancel"

      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} -> [hello()]
          _ -> []
        end)
      )

      assert_receive {:host_sent, %{"t" => "hello"}}, 5_000

      sent =
        for _ <- 1..256 do
          assert_receive {:host_sent, %{"t" => "cancel", "op_id" => op_id}}, 5_000
          op_id
        end

      refute_receive {:host_sent, %{"t" => "cancel"}}, 300
      assert Enum.sort(sent) == Enum.sort(Enum.map(newest, & &1.op_id))
    end

    test "a guest that stops reading doesn't hold the link up", ctx do
      test = self()

      start_fake_vm(ctx, fn socket ->
        {:ok, _hello} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, hello())
        # Never reads again, and stays connected for as long as the test runs.
        ref = Process.monitor(test)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        end
      end)

      link = start_link(ctx, send_timeout: 200)
      assert_receive :vm_connected, 5_000
      wait_until(fn -> Link.connected?(link) end)

      # Each is more than the socket holds: the first is queued, and the
      # second blocks.
      files = %{"secrets.env" => String.duplicate("A=b\n", 250_000)}
      run_async(link, secrets(files))
      run_async(link, secrets(files))

      # The send gives up, and the link starts again.
      assert_receive :vm_connected, 3_000
      assert is_boolean(Link.connected?(link))
    end

    test "a connection that fails partway is closed", ctx do
      # The VM answers, and hangs up before the link's hello.
      start_fake_vm(ctx, &:gen_tcp.close/1)
      link = start_link(ctx, retry: 5, max_retry: 20)

      Process.sleep(1_000)
      assert ports(link) <= 1
    end

    test "a guest that keeps hanging up is retried less and less often", ctx do
      start_fake_vm(ctx, fn socket ->
        {:ok, _hello} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.send(socket, hello())
        :gen_tcp.close(socket)
      end)

      start_link(ctx, retry: 50, max_retry: 400)
      Process.sleep(1_000)

      # 0, 50, 150, 350, 750 ms
      assert count_received(:vm_connected) in 2..8
    end

    test "a guest that sends a bad length is warned about once", ctx do
      start_fake_vm(ctx, fn socket ->
        {:ok, _hello} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :inet.setopts(socket, packet: :raw)
        :gen_tcp.send(socket, <<0xFFFFFFFF::32>>)
        Process.sleep(1_000)
      end)

      log =
        capture_log(fn ->
          start_link(ctx, retry: 10, max_retry: 40)
          Process.sleep(1_000)
        end)

      assert count_received(:vm_connected) >= 3
      assert length(String.split(log, ctx.vsock)) - 1 == 1
    end

    test "query replies are checked", ctx do
      start_fake_vm(
        ctx,
        reactive(fn
          %{"t" => "hello"} ->
            [hello("0.1.0\e[31m\n")]

          %{"t" => "query", "id" => id, "q" => "inventory"} ->
            [reply(id, %{"ok" => true, "result" => "not a list"})]

          %{"t" => "query", "id" => id, "q" => "ports"} ->
            [reply(id, %{"ok" => true, "result" => %{"x" => String.duplicate("a", 300_000)}})]

          %{"t" => "query", "id" => id} ->
            [reply(id, %{"ok" => false, "error" => "no\e such\nquery"})]

          _ ->
            []
        end)
      )

      link = start_link(ctx)
      wait_until(fn -> Link.connected?(link) end)

      invalid = {:error, "the environment's VM sent an invalid reply"}
      assert Link.query(link, "inventory") == invalid
      assert Link.query(link, "ports") == invalid
      assert Link.query(link, "other") == {:error, "no suchquery"}
      assert :sys.get_state(link).guest_version == "0.1.0[31m"
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end
end
