defmodule ForemanAgent.Runner.TreeTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Runner.{Local, Tree}

  # Cancelling an operation stops what its commands started. Commands it
  # runs side by side are started from tasks, which own those ports.
  test "os_pids/1 finds the programs an operation's tasks started, as well as its own" do
    test_pid = self()

    operation =
      spawn(fn ->
        task = Task.async(fn -> Local.run("sleep", ["30"], []) end)
        send(test_pid, {:task, task.pid})
        Local.run("sleep", ["31"], [])
      end)

    assert_receive {:task, _task_pid}

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(20)
             length(Tree.os_pids(operation)) == 2
           end)

    roots = Tree.os_pids(operation)
    Tree.terminate(roots, 1_000)
    Process.exit(operation, :kill)

    # Someone else's commands aren't this operation's.
    assert Tree.os_pids(self()) == []
  end

  # A task that hasn't started its command yet when the operation is
  # cancelled would start it after the snapshot of what to stop. It's
  # found by its link to the operation, which it has from the moment it
  # exists: before it has run at all, and whatever kind of process it is.
  test "freeze/2 stops what an operation started where it is, and nothing else" do
    test_pid = self()

    keeper =
      spawn(fn ->
        operation =
          spawn_link(fn ->
            child =
              spawn_link(fn ->
                grandchild = spawn_link(fn -> wait_then(test_pid, :grandchild_ran) end)
                send(test_pid, {:grandchild, grandchild})
                wait_then(test_pid, :child_ran)
              end)

            send(test_pid, {:child, child})
            Process.sleep(:infinity)
          end)

        send(test_pid, {:operation, operation})
        wait_then(test_pid, :keeper_ran)
      end)

    assert_receive {:operation, operation}
    assert_receive {:child, child}
    assert_receive {:grandchild, grandchild}

    assert Enum.sort(Tree.freeze(operation, [keeper])) == Enum.sort([child, grandchild])

    for pid <- [child, grandchild, keeper], do: send(pid, :go)
    assert_receive :keeper_ran
    refute_receive :child_ran, 100
    refute_received :grandchild_ran

    Process.exit(operation, :kill)
  end

  defp wait_then(test_pid, message) do
    receive do
      :go -> send(test_pid, message)
    end
  end
end
