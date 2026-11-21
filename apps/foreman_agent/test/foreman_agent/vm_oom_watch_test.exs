defmodule ForemanAgent.VMOomWatchTest do
  # The kernel's OOM kills inside a VM, read from the console the VM
  # writes on the box.
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, VM}
  alias ForemanAgent.VM.OomWatch

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @other "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  defp killed(pid, comm, cause \\ "Out of memory") do
    "[ 1234.567890] #{cause}: Killed process #{pid} (#{comm}) total-vm:2345678kB, " <>
      "anon-rss:1234567kB, file-rss:1234kB, shmem-rss:0kB, UID:1000 pgtables:4567kB oom_score_adj:0\r\n"
  end

  describe "parse/1" do
    test "names the processes the kernel killed, VM-wide or in a container's cgroup" do
      console =
        "[    0.000000] Linux version 6.8.0\r\n" <>
          killed(4321, "orca") <>
          "[ 1300.000000] systemd[1]: Failed to start something.\r\n" <>
          killed(777, "node", "Memory cgroup out of memory") <>
          killed(4400, "orca")

      assert OomWatch.parse(console) == ["orca", "node", "orca"]
    end

    test "nothing else on the console is a kill" do
      assert OomWatch.parse("") == []
      assert OomWatch.parse("node invoked oom-killer: gfp_mask=0x140cca, order=0\r\n") == []
      assert OomWatch.parse("oom_reaper: reaped process 4321 (orca), now anon-rss:0kB\r\n") == []
    end

    test "a name that would draw on a terminal counts as a kill without a name" do
      assert OomWatch.parse(killed(1, "a\e[31mb") <> killed(2, "tail")) == [nil, "tail"]
    end
  end

  describe "the VM file helper's read-log" do
    setup do
      dir = Path.join(System.tmp_dir!(), "oom-log-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{path: Path.join(dir, "serial.log")}
    end

    defp read_log(path, offset) do
      case System.cmd(VM.file_helper(), ["read-log", path, Integer.to_string(offset)]) do
        {out, 0} ->
          [next, data] = String.split(out, "\n", parts: 2)
          {String.to_integer(next), data}

        {"", status} ->
          {:error, status}
      end
    end

    test "gives the whole lines written since an offset, and where to read from next", ctx do
      File.write!(ctx.path, "one\ntwo\nthr")
      assert read_log(ctx.path, 0) == {8, "one\ntwo\n"}
      assert read_log(ctx.path, 4) == {8, "two\n"}
      # A line still being written waits for its end.
      assert read_log(ctx.path, 8) == {8, ""}
      File.write!(ctx.path, "ee\n", [:append])
      assert read_log(ctx.path, 8) == {14, "three\n"}
    end

    test "starts again when the console was cut shorter than the offset", ctx do
      File.write!(ctx.path, "new\n")
      assert read_log(ctx.path, 5_000) == {4, "new\n"}
    end

    test "reads only the last 64 KiB of a console that wrote more", ctx do
      File.write!(ctx.path, :binary.copy("x", 100_000) <> "\nlast\n")
      assert {100_006, data} = read_log(ctx.path, 0)
      assert byte_size(data) == 65_536
      assert String.ends_with?(data, "x\nlast\n")

      # With no line end in all of it, there's nothing to wait for.
      File.write!(ctx.path, :binary.copy("x", 100_000))
      assert read_log(ctx.path, 0) == {100_000, ""}
    end

    test "refuses a bad offset, and a console that's a link", ctx do
      File.write!(ctx.path, "one\n")
      assert {"", 1} = System.cmd(VM.file_helper(), ["read-log", ctx.path, "-1"])
      assert {"", 1} = System.cmd(VM.file_helper(), ["read-log", ctx.path, "x"])

      File.ln_s!(ctx.path, ctx.path <> ".symlink")
      File.ln!(ctx.path, ctx.path <> ".hardlink")

      for name <- [ctx.path <> ".symlink", ctx.path <> ".hardlink"] do
        assert {"", 1} = System.cmd(VM.file_helper(), ["read-log", name, "0"])
      end
    end
  end

  describe "scan/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "oom-scan-#{System.unique_integer([:positive])}")
      config = %{Config.get() | vm_root: Path.join(dir, "vms")}
      on_exit(fn -> File.rm_rf!(dir) end)

      for env <- [@env, @other] do
        File.mkdir_p!(VM.paths(config, env).dir)
        VM.write_meta(config, env, %{"slug" => "a-1"})
      end

      %{config: config, serial: VM.paths(config, @env).serial}
    end

    test "reports kills written since the last look, and none from before the first", ctx do
      File.write!(ctx.serial, killed(1, "old"))
      assert {report, cursors} = OomWatch.scan(ctx.config, %{})
      assert report == %{}

      # The other VM has no console yet.
      assert Map.keys(cursors) == [@env]

      assert {%{}, ^cursors} = OomWatch.scan(ctx.config, cursors)

      File.write!(ctx.serial, killed(2, "orca") <> killed(3, "node") <> killed(4, "orca"), [
        :append
      ])

      assert {report, cursors} = OomWatch.scan(ctx.config, cursors)
      assert report == %{@env => %{processes: ["orca", "node"]}}

      assert {%{}, ^cursors} = OomWatch.scan(ctx.config, cursors)
    end

    test "a kill it can't name is still reported", ctx do
      File.write!(ctx.serial, "")
      {_, cursors} = OomWatch.scan(ctx.config, %{})
      File.write!(ctx.serial, killed(2, "\e[2J"), [:append])

      assert {%{@env => %{processes: []}}, _} = OomWatch.scan(ctx.config, cursors)
    end

    test "names at most eight processes from one look", ctx do
      File.write!(ctx.serial, "")
      {_, cursors} = OomWatch.scan(ctx.config, %{})
      File.write!(ctx.serial, Enum.map_join(1..20, &killed(&1, "p#{&1}")), [:append])

      assert {%{@env => %{processes: names}}, _} = OomWatch.scan(ctx.config, cursors)
      assert names == Enum.map(1..8, &"p#{&1}")
    end

    test "reads a console that started again from its beginning", ctx do
      File.write!(ctx.serial, String.duplicate("boot\r\n", 100))
      {_, cursors} = OomWatch.scan(ctx.config, %{})

      # Cut (past 16 MB), or the VM booted again into the same file.
      File.write!(ctx.serial, killed(2, "orca"))
      assert {%{@env => %{processes: ["orca"]}}, cursors} = OomWatch.scan(ctx.config, cursors)

      # A new file in its place, already longer than the old one was read to.
      File.rm!(ctx.serial)
      File.write!(ctx.serial <> ".new", String.duplicate("boot\r\n", 100) <> killed(3, "node"))
      File.rename!(ctx.serial <> ".new", ctx.serial)
      assert {%{@env => %{processes: ["node"]}}, _} = OomWatch.scan(ctx.config, cursors)
    end

    test "doesn't follow a console the VM replaced with a link", ctx do
      File.write!(ctx.serial, "")
      {_, cursors} = OomWatch.scan(ctx.config, %{})

      elsewhere = Path.join(Path.dirname(ctx.config.vm_root), "elsewhere")
      File.write!(elsewhere, killed(2, "orca"))
      File.rm!(ctx.serial)
      File.ln_s!(elsewhere, ctx.serial)

      assert {%{}, cursors} = OomWatch.scan(ctx.config, cursors)
      assert cursors == %{}
    end

    test "forgets a VM that's gone", ctx do
      File.write!(ctx.serial, "")
      {_, cursors} = OomWatch.scan(ctx.config, %{})
      assert Map.has_key?(cursors, @env)

      File.rm_rf!(VM.paths(ctx.config, @env).dir)
      File.rm!(VM.paths(ctx.config, @env).meta)
      assert {%{}, %{}} == OomWatch.scan(ctx.config, cursors)
    end
  end
end
