defmodule ForemanAgent.Runner.LocalTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Runner.{Collector, Local, TimedCommand}

  @moduletag :tmp_dir

  defp alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(100)
        eventually(fun, tries - 1)
    end
  end

  describe "timeouts" do
    test "a timeout kills the whole process tree of the command", %{tmp_dir: tmp} do
      pidfile = Path.join(tmp, "grandchild.pid")
      # The child forks a grandchild and waits for it, like the devcontainer
      # CLI waiting on `docker compose up`.
      script = ~S(sh -c 'echo $$ > "$1"; echo ready; exec sleep 300' sh "$1"; echo parent-done)
      port = TimedCommand.open("sh", ["-c", script, "sh", pidfile], [])

      # Expire the deadline only after the grandchild exists. The ready
      # message follows the pidfile write, so there is no startup race.
      assert_receive {^port, {:data, ready}}, 30_000
      MuonTrap.Port.report_bytes_handled(port, byte_size(ready))
      grandchild = File.read!(pidfile) |> String.trim()
      on_exit(fn -> System.cmd("kill", ["-9", grandchild], stderr_to_stdout: true) end)

      assert {_, :timeout} = TimedCommand.await(port, "", 0)
      assert eventually(fn -> not alive?(grandchild) end), "grandchild #{grandchild} survived"
    end

    test "a deadline during startup still stops the command" do
      assert {:ok, %{status: :timeout}} = Local.run("sleep", ["300"], timeout: 0)
    end

    test "a command that finishes in time keeps its exit status" do
      assert {:ok, %{status: 3, output: "hi\n"}} =
               Local.run("sh", ["-c", "echo hi; exit 3"], timeout: 60_000)
    end

    test "a deadline with the exit status already queued preserves that status" do
      port = TimedCommand.open("sh", ["-c", "echo hi; exit 3"], [])
      monitor = Port.monitor(port)
      assert_receive {^port, {:data, "hi\n"}}, 30_000
      MuonTrap.Port.report_bytes_handled(port, 3)
      assert_receive {:DOWN, ^monitor, :port, ^port, _}, 30_000

      # The deadline expires with the real exit status already queued.
      assert {"", 3} = TimedCommand.await(port, "", 0)
    end
  end

  describe "output is always valid UTF-8" do
    test "characters split across pipe reads are delivered whole" do
      test_pid = self()
      # head writes in buffer-sized blocks, which cut characters in two.
      script = "yes '€€€€€€€€€€' 2>/dev/null | head -n 10000"

      {:ok, %{status: 0, output: output}} =
        Local.run("sh", ["-c", script], on_output: &send(test_pid, {:chunk, &1}))

      chunks = collect()
      assert length(chunks) > 1
      assert Enum.all?(chunks, &String.valid?/1)
      assert IO.iodata_to_binary(chunks) == String.duplicate("€€€€€€€€€€\n", 10_000)
      assert String.valid?(output)
    end

    test "invalid bytes are replaced rather than passed on" do
      test_pid = self()

      {:ok, %{output: output}} =
        Local.run("sh", ["-c", "printf 'caf\\351 latin-1\\n'"],
          on_output: &send(test_pid, {:chunk, &1})
        )

      assert IO.iodata_to_binary(collect()) == "caf� latin-1\n"
      assert output == "caf� latin-1\n"
    end

    test "the kept tail starts on a character boundary" do
      collector = Enum.into(["build failed: ", "ééééé"], %Collector{keep: 9, on_output: & &1})
      output = Collector.output(collector)
      assert String.valid?(output)
      assert output == "éééé"
    end
  end

  describe "stdin" do
    # MuonTrap's own stdin carries the acks that let it forward more output.
    # `docker exec -i`, which the agent's own implementation of the
    # devcontainer CLI's `up` runs lifecycle commands with, reads stdin,
    # and a command that inherited it would swallow them and stall its
    # output.
    test "a command that reads stdin gets none and its output keeps flowing" do
      # sh gives a background job /dev/null for stdin, so the reader is the
      # foreground one.
      script = "head -c 200000 /dev/zero | tr '\\0' x & cat >/dev/null; wait"

      assert {:ok, %{status: status, output: output}} =
               Local.run("sh", ["-c", script], keep: 262_144, timeout: 10_000)

      assert {status, byte_size(output)} == {0, 200_000}
      assert output == String.duplicate("x", 200_000)
    end
  end

  defp collect(acc \\ []) do
    receive do
      {:chunk, chunk} -> collect([chunk | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "visible_env/1" do
    test "is the environment a command really gets" do
      given = %{"A" => "1", "HOME" => "/somewhere/else"}
      {:ok, %{status: 0, output: output}} = Local.run("env", [], env: given)

      seen =
        for line <- String.split(output, "\n", trim: true),
            [name, value] <- [String.split(line, "=", parts: 2)],
            # What the shell that runs the command sets for itself.
            name not in ["PWD", "OLDPWD", "SHLVL", "_"],
            into: %{},
            do: {name, value}

      assert Local.visible_env(given) == seen
      assert seen["A"] == "1"
      assert seen["HOME"] == "/somewhere/else"
      assert is_binary(seen["PATH"])
    end
  end
end
