defmodule ForemanAgent.OpsTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Ops
  alias ForemanProtocol.Command

  @env1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @env2 "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  setup do
    test_pid = self()

    # The handler reports to the test and waits to be released, so tests
    # control when an operation finishes.
    handler = fn cmd, log ->
      log.("info", "started #{cmd.type}\n")
      send(test_pid, {:started, cmd.op_id, self()})

      receive do
        {:finish, result} -> result
      end
    end

    sink = fn event -> send(test_pid, {:event, event.type, event.payload}) end
    ops = start_supervised!({Ops, name: nil, handler: handler, sink: sink})
    %{ops: ops}
  end

  defp command(type, payload) do
    {:ok, cmd} = Command.new(type, payload)
    cmd
  end

  defp stop_cmd(env_id), do: command("env.stop", %{env_id: env_id, slug: "x"})

  defp finish(pid, result \\ {:ok, %{}}), do: send(pid, {:finish, result})

  test "runs a command and reports accepted, logs and result", %{ops: ops} do
    cmd = stop_cmd(@env1)
    assert :accepted = Ops.submit(ops, cmd)

    op_id = cmd.op_id
    assert_receive {:event, "op.accepted", %{op_id: ^op_id}}
    assert_receive {:started, ^op_id, pid}
    assert_receive {:event, "op.log", %{op_id: ^op_id, data: "started env.stop\n"}}

    finish(pid, {:ok, %{"done" => true}})

    assert_receive {:event, "op.result",
                    %{op_id: ^op_id, status: "ok", result: %{"done" => true}}}

    assert Ops.in_flight(ops) == []
  end

  test "reports errors as error results", %{ops: ops} do
    cmd = stop_cmd(@env1)
    Ops.submit(ops, cmd)
    assert_receive {:started, _, pid}
    finish(pid, {:error, "boom"})
    assert_receive {:event, "op.result", %{status: "error", error: "boom"}}
  end

  test "a crashing handler becomes an error result", %{ops: ops} do
    cmd = stop_cmd(@env1)
    Ops.submit(ops, cmd)
    assert_receive {:started, _, pid}
    Process.exit(pid, :kill)
    assert_receive {:event, "op.result", %{status: "error", error: error}}
    assert error =~ "crashed"
  end

  test "a duplicate op_id is not run twice", %{ops: ops} do
    cmd = stop_cmd(@env1)
    assert :accepted = Ops.submit(ops, cmd)
    assert :duplicate = Ops.submit(ops, cmd)

    assert_receive {:started, _, pid}
    refute_receive {:started, _, _}, 50

    finish(pid)
    assert_receive {:event, "op.result", %{status: "ok"}}

    # Once finished, a retry gets the stored result again rather than a rerun.
    assert :duplicate = Ops.submit(ops, cmd)
    assert_receive {:event, "op.result", %{status: "ok"}}
    refute_receive {:started, _, _}, 50
  end

  test "operations on the same environment run one at a time, in order", %{ops: ops} do
    first = stop_cmd(@env1)
    second = command("env.start", %{env_id: @env1, slug: "x"})
    other = stop_cmd(@env2)

    Ops.submit(ops, first)
    Ops.submit(ops, second)
    Ops.submit(ops, other)

    first_id = first.op_id
    other_id = other.op_id
    second_id = second.op_id

    assert_receive {:started, ^first_id, first_pid}
    assert_receive {:started, ^other_id, _}
    refute_receive {:started, ^second_id, _}, 50

    finish(first_pid)
    assert_receive {:started, ^second_id, _}
  end

  test "box commands don't wait on environments", %{ops: ops} do
    Ops.submit(ops, stop_cmd(@env1))
    inventory = command("box.inventory", %{})
    Ops.submit(ops, inventory)
    inventory_id = inventory.op_id
    assert_receive {:started, ^inventory_id, _}
  end

  test "cancel kills a running operation and drops queued ones", %{ops: ops} do
    running = stop_cmd(@env1)
    queued = command("env.start", %{env_id: @env1, slug: "x"})
    Ops.submit(ops, running)
    Ops.submit(ops, queued)
    assert_receive {:started, _, pid}
    ref = Process.monitor(pid)

    Ops.submit(ops, command("op.cancel", %{target_op_id: running.op_id}))
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    running_id = running.op_id

    assert_receive {:event, "op.result",
                    %{op_id: ^running_id, status: "error", error: "cancelled"}}

    Ops.submit(ops, command("op.cancel", %{target_op_id: queued.op_id}))
    queued_id = queued.op_id

    assert_receive {:event, "op.result",
                    %{op_id: ^queued_id, status: "error", error: "cancelled"}}
  end

  test "in_flight lists running and queued op ids", %{ops: ops} do
    a = stop_cmd(@env1)
    b = command("env.start", %{env_id: @env1, slug: "x"})
    Ops.submit(ops, a)
    Ops.submit(ops, b)
    assert_receive {:started, _, _}
    assert Enum.sort(Ops.in_flight(ops)) == Enum.sort([a.op_id, b.op_id])
  end
end
