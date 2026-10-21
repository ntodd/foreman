defmodule ForemanAgent.Runner.LocalTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Runner.{Collector, Local}

  @moduletag :tmp_dir

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
      script = "sh -c 'echo $$ > #{pidfile}; exec sleep 300'; echo parent-done"

      task = Task.async(fn -> Local.run("sh", ["-c", script], timeout: 500) end)
      grandchild = wait_for_file(pidfile)
      on_exit(fn -> System.cmd("kill", ["-9", grandchild], stderr_to_stdout: true) end)

      assert {:ok, %{status: :timeout}} = Task.await(task, 15_000)
      assert eventually(fn -> not alive?(grandchild) end), "grandchild #{grandchild} survived"
    end

    test "a command that finishes in time keeps its exit status" do
      assert {:ok, %{status: 3, output: "hi\n"}} =
               Local.run("sh", ["-c", "echo hi; exit 3"], timeout: 5_000)
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
    # The devcontainer CLI reads stdin during lifecycle commands, and a
    # command that inherited it would swallow them and stall its output.
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
end
