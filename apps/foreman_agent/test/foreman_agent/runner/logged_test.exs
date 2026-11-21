defmodule ForemanAgent.Runner.LoggedTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Runner.Logged

  describe "shown/1" do
    test "is a command's whole output as the log shows it" do
      assert Logged.shown("one\n\e[32mtwo\e[0m\r\n\nprogress 1\rprogress 2\nlast") ==
               "one\ntwo\n\nprogress 2\nlast"
    end

    test "is empty for no output" do
      assert Logged.shown("") == ""
    end
  end

  describe "run/5" do
    import Mox

    setup :verify_on_exit!

    setup do
      test_pid = self()

      %{
        ctx: %{
          runner: ForemanAgent.RunnerMock,
          log: fn stream, data -> send(test_pid, {:log, stream, data}) end
        }
      }
    end

    # A command that prints `chunks`, then exits with `status`.
    defp prints(chunks, status \\ 0) do
      stub(ForemanAgent.RunnerMock, :run, fn "tool", [], opts ->
        Enum.each(chunks, opts[:on_output])
        {:ok, %{status: status, output: Enum.join(chunks)}}
      end)
    end

    defp logged(acc \\ []) do
      receive do
        {:log, "info", text} -> logged([text | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "logs output a line at a time, however it arrives", %{ctx: ctx} do
      prints(["one\ntw", "o\nthree"])

      assert {:ok, %{status: 0}} = Logged.run(ctx, "tool", [], [])
      assert logged() == ["one\n", "two\n", "three\n"]
    end

    test "collapses spinner frames and cursor redraws in the log and in what's quoted", %{
      ctx: ctx
    } do
      frames =
        for i <- 0..39 do
          glyph = Enum.at(~w(◐ ◓ ◑ ◒), rem(i, 4))
          dots = String.duplicate(".", div(i, 10))
          "\e[1G\e[J#{glyph}  Cloning repository…#{dots}\n"
        end

      chunks =
        ["◇  Source: https://github.com/stablyai/orca.git\n"] ++
          Enum.take(frames, 20) ++ ["\e[1D\n", "\e[0K\n"] ++ Enum.drop(frames, 20)

      prints(chunks, 1)

      assert {:ok, %{status: 1, output: output}} = Logged.run(ctx, "tool", [], [])

      quoted = Logged.last_lines(output)
      assert quoted =~ "Source: https://github.com/stablyai/orca.git"
      assert length(String.split(quoted, "Cloning repository")) == 2

      logged = logged()
      assert Enum.count(logged, &(&1 =~ "Cloning repository")) == 1
      assert "◐  Cloning repository…\n" in logged
      refute "\n" in logged
    end

    test "collapses spinner frames that arrive together", %{ctx: ctx} do
      frames = for i <- 0..19, do: "#{Enum.at(~w(◐ ◓ ◑ ◒), rem(i, 4))}  Cloning repository…\n"
      prints([Enum.join(["Source: repo\n" | frames])], 1)

      assert {:ok, %{output: output}} = Logged.run(ctx, "tool", [], [])

      quoted = Logged.last_lines(output)
      assert quoted =~ "Source: repo"
      assert length(String.split(quoted, "Cloning repository")) == 2
    end

    test "shows only the last of frames redrawn on one line", %{ctx: ctx} do
      redraws =
        Enum.map_join(0..19, fn i ->
          "\e[1G\e[J#{Enum.at(~w(◐ ◓ ◑ ◒), rem(i, 4))}  Cloning repository…"
        end)

      prints(
        ["Source: repo\n" <> redraws <> "\n", "\r\n", "\e[1G\e[J◐  Cloning repository….\n"],
        1
      )

      assert {:ok, %{output: output}} = Logged.run(ctx, "tool", [], [])

      quoted = Logged.last_lines(output)
      assert quoted =~ "Source: repo\n◒  Cloning repository…"
      assert length(String.split(quoted, "Cloning repository")) == 2

      logged = logged()
      assert Enum.count(logged, &(&1 =~ "Cloning repository")) == 1
      refute "\n" in logged
    end

    test "a tool that isn't installed, and one that runs out of time", %{ctx: ctx} do
      stub(ForemanAgent.RunnerMock, :run, fn "tool", [], _opts ->
        {:error, {:not_found, "tool"}}
      end)

      assert Logged.run(ctx, "tool", [], []) == {:error, "tool is not installed on this box"}

      stub(ForemanAgent.RunnerMock, :run, fn "tool", [], _opts ->
        {:ok, %{status: :timeout, output: ""}}
      end)

      assert Logged.run(ctx, "tool", [], timeout: 120_000, label: "the tool") ==
               {:error, "the tool timed out after 2 minutes and was stopped"}

      assert Logged.run(ctx, "tool", [], timeout: 120_000, timed_out: "all of it took too long") ==
               {:error, "all of it took too long"}
    end
  end
end
