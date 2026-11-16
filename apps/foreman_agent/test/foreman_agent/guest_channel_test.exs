defmodule ForemanAgent.GuestChannelTest do
  # The host's link to a real guest agent (Guest.Server, Ops and Outbox)
  # through a stand-in for Cloud Hypervisor's hybrid vsock.
  use ExUnit.Case, async: true

  alias ForemanAgent.{Channel, Ops, Outbox}
  alias ForemanAgent.Guest.Server
  alias ForemanAgent.Test.VsockBridge
  alias ForemanAgent.VM.Link
  alias ForemanProtocol.Command

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
    test = self()

    handler = fn cmd, log ->
      log.("stdout", "running #{cmd.type}\n")
      send(test, {:started, cmd.op_id, self()})

      receive do
        {:finish, result} -> result
      end
    end

    outbox = start_supervised!({Outbox, name: nil}, id: :outbox)

    ops =
      start_supervised!(
        {Ops, name: nil, handler: handler, sink: &Outbox.push(outbox, &1)},
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
    bridge = start_supervised!({VsockBridge, path: ctx.vsock, target: ctx.guest}, id: :bridge)
    %{ops: ops, outbox: outbox, bridge: bridge}
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

  defp run_async(link, cmd) do
    test = self()

    spawn(fn ->
      log = fn stream, data -> send(test, {:log, stream, data}) end
      send(test, {:result, Link.run(link, cmd, log)})
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

  test "queries are answered", ctx do
    start_guest(ctx)
    link = start_link(ctx)
    wait_until(fn -> Link.connected?(link) end)

    assert {:ok, [%{"env_id" => @env}]} = Link.query(link, "inventory")
    assert {:error, "unknown query"} = Link.query(link, "secrets")
  end

  test "a VM that stops fails the commands waiting on it", ctx do
    %{bridge: bridge} = start_guest(ctx)
    alive = :atomics.new(1, [])
    :atomics.put(alive, 1, 1)
    link = start_link(ctx, alive?: fn -> :atomics.get(alive, 1) == 1 end)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)
    assert_receive {:started, ^op_id, _pid}, 5_000

    :atomics.put(alive, 1, 0)
    VsockBridge.stop(bridge)

    assert_receive {:result, {:error, "the environment's VM isn't running"}}, 5_000
  end

  test "the guest refuses commands the box runs itself" do
    {:ok, cmd} = Command.new("box.restart", %{boot_id: @env})

    assert {:error, "box.restart isn't run in an environment's VM"} =
             ForemanAgent.Guest.handle(cmd, fn _, _ -> :ok end)
  end

  test "a guest that never says hello isn't connected, and gets nothing", ctx do
    start_fake_guest(ctx, fn _ -> [] end)
    link = start_link(ctx)
    cmd = command()
    op_id = cmd.op_id
    run_async(link, cmd)

    assert_receive {:host_sent, %{"t" => "hello"}}, 5_000
    refute Link.connected?(link)
    assert {:error, :not_connected} = Link.query(link, "inventory")
    refute_receive {:host_sent, %{"t" => "cmd", "cmd" => %{"op_id" => ^op_id}}}, 500
  end

  describe "a hostile guest" do
    # A fake guest that answers the link's command with junk around the
    # real result.
    defp start_fake_guest(ctx, script) do
      test = self()
      _ = File.rm(ctx.guest)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, ctx.guest}}, active: false])

      spawn_link(fn -> fake_accept(listen, test, script) end)
      start_supervised!({VsockBridge, path: ctx.vsock, target: ctx.guest}, id: :bridge)
    end

    defp fake_accept(listen, test, script) do
      {:ok, socket} = :gen_tcp.accept(listen)
      :ok = :inet.setopts(socket, Channel.frame_opts())
      spawn_link(fn -> fake_accept(listen, test, script) end)
      fake_serve(socket, test, script)
    end

    defp fake_serve(socket, test, script) do
      case :gen_tcp.recv(socket, 0) do
        {:ok, data} ->
          {:ok, frame} = Channel.decode(data)
          send(test, {:host_sent, frame})
          for reply <- script.(frame), do: :gen_tcp.send(socket, reply)
          fake_serve(socket, test, script)

        {:error, _} ->
          :ok
      end
    end

    defp hello, do: Channel.encode(%{"t" => "hello", "agent_version" => "0.1.0"})

    defp event(type, payload, seq \\ nil) do
      {:ok, event} = ForemanProtocol.Event.new(type, payload)

      Channel.encode(%{
        "t" => "event",
        "seq" => seq,
        "event" => ForemanProtocol.Event.to_wire(event)
      })
    end

    test "only the result for the command reaches the caller", ctx do
      other = ForemanProtocol.uuid()

      start_fake_guest(ctx, fn
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
            event("op.log", %{op_id: other, stream: "stdout", data: "someone else's\n"}),
            event("op.result", %{op_id: other, status: "ok", result: %{"forged" => true}}, 1),
            event("box.inventory", %{environments: []}),
            event("op.log", %{op_id: op_id, stream: "stdout", data: "mine\n"}),
            event("op.result", %{op_id: op_id, status: "ok", result: %{"real" => true}}, 2)
          ]

        _ ->
          []
      end)

      link = start_link(ctx)
      run_async(link, command())

      assert_receive {:result, {:ok, %{"real" => true}}}, 5_000
      assert_receive {:log, "stdout", "mine\n"}
      refute_received {:log, _, "someone else's\n"}
      # Results are acknowledged, so the guest doesn't send them forever.
      assert_receive {:host_sent, %{"t" => "ack", "seq" => 1}}, 5_000
      assert_receive {:host_sent, %{"t" => "ack", "seq" => 2}}, 5_000
    end

    test "an oversized frame drops the connection, and the link reconnects", ctx do
      counter = :counters.new(1, [])

      start_fake_guest(ctx, fn
        %{"t" => "hello"} ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: [:binary.copy("x", Channel.max_frame() + 1)],
            else: [hello()]

        %{"t" => "cmd", "cmd" => %{"op_id" => op_id}} ->
          [event("op.result", %{op_id: op_id, status: "ok", result: %{"after" => true}}, 1)]

        _ ->
          []
      end)

      link = start_link(ctx)
      run_async(link, command())

      assert_receive {:result, {:ok, %{"after" => true}}}, 10_000
      assert :counters.get(counter, 1) >= 2
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
