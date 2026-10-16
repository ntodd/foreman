defmodule ForemanAgent.OpsCancelTest do
  # Cancelling uses real commands, so it runs on its own.
  use ExUnit.Case, async: false

  alias ForemanAgent.{Ops, Runner}
  alias ForemanProtocol.Command

  @moduletag :tmp_dir
  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  defp alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end

  defp wait_for_file(path, tries \\ 100) do
    case File.read(path) do
      {:ok, pid} when pid != "" ->
        String.trim(pid)

      _ when tries > 0 ->
        Process.sleep(20)
        wait_for_file(path, tries - 1)
    end
  end

  defp command(type, payload) do
    {:ok, cmd} = Command.new(type, payload)
    cmd
  end

  test "cancel kills grandchildren of the command, and the next operation waits for them",
       %{tmp_dir: tmp} do
    pidfile = Path.join(tmp, "grandchild.pid")
    test_pid = self()
    script = "sh -c 'echo $$ > #{pidfile}; exec sleep 300'; echo parent-done"

    handler = fn
      %Command{type: "env.stop"}, log ->
        Runner.Local.run("sh", ["-c", script], on_output: &log.("stdout", &1))

      %Command{type: "env.start"}, _log ->
        grandchild = wait_for_file(pidfile)
        send(test_pid, {:next_started, alive?(grandchild)})
        {:ok, %{}}
    end

    sink = fn event -> send(test_pid, {:event, event.type, event.payload}) end
    ops = start_supervised!({Ops, name: nil, handler: handler, sink: sink})

    stop = command("env.stop", %{env_id: @env, slug: "x"})
    start = command("env.start", %{env_id: @env, slug: "x"})
    :accepted = Ops.submit(ops, stop)
    :accepted = Ops.submit(ops, start)

    grandchild = wait_for_file(pidfile)
    on_exit(fn -> System.cmd("kill", ["-9", grandchild], stderr_to_stdout: true) end)

    :accepted = Ops.submit(ops, command("op.cancel", %{target_op_id: stop.op_id}))
    stop_id = stop.op_id
    assert_receive {:event, "op.result", %{op_id: ^stop_id, error: "cancelled"}}

    assert_receive {:next_started, grandchild_alive?}, 15_000
    refute grandchild_alive?, "the next operation started while the cancelled one's tree ran"
    refute alive?(grandchild)
  end

  test "a crash is reported without the crash's data" do
    test_pid = self()
    handler = fn _cmd, _log -> raise "can't use ghp_SECRETSECRETSECRET" end
    sink = fn event -> send(test_pid, {:event, event.type, event.payload}) end
    ops = start_supervised!({Ops, name: nil, handler: handler, sink: sink})

    cmd = command("env.stop", %{env_id: @env, slug: "x"})
    Ops.submit(ops, cmd)
    op_id = cmd.op_id
    assert_receive {:event, "op.result", %{op_id: ^op_id, status: "error", error: error}}
    assert error =~ "operation crashed"
    refute error =~ "SECRET"
  end

  test "logs and results with invalid UTF-8 are scrubbed before they become events" do
    test_pid = self()

    handler = fn _cmd, log ->
      log.("stdout", "caf\xE9\n")
      {:error, "failed: \xFF"}
    end

    sink = fn event -> send(test_pid, {:event, event.type, event.payload}) end
    ops = start_supervised!({Ops, name: nil, handler: handler, sink: sink})

    cmd = command("env.stop", %{env_id: @env, slug: "x"})
    Ops.submit(ops, cmd)
    assert_receive {:event, "op.log", %{data: "caf�\n"}}
    assert_receive {:event, "op.result", %{status: "error", error: "failed: �"}}
  end
end
