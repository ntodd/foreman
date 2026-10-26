defmodule ForemanAgent.PortsTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, Ports}

  @e1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @e2 "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  @header "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

  setup :verify_on_exit!

  # One /proc/net/tcp line: little-endian address words, big-endian port.
  defp line(local, state, inode, remote \\ "00000000:0000") do
    "   0: #{local} #{remote} #{state} 00000000:00000000 00:00000000 00000000  1000        0 #{inode} 1 0000000000000000 100 0 0 10 0\n"
  end

  defp line6(local, state, inode) do
    line(local, state, inode, "00000000000000000000000000000000:0000")
  end

  describe "parse/1" do
    test "reads listening IPv4 sockets: address, port and inode" do
      text =
        @header <>
          line("0100007F:0FA0", "0A", 1001) <>
          line("00000000:1388", "0A", 1002) <>
          line("0200A8C0:0050", "0A", 1003)

      assert Ports.parse(text) == [
               %{address: {127, 0, 0, 1}, port: 4000, inode: 1001},
               %{address: {0, 0, 0, 0}, port: 5000, inode: 1002},
               %{address: {192, 168, 0, 2}, port: 80, inode: 1003}
             ]
    end

    test "reads listening IPv6 sockets" do
      text =
        @header <>
          line6("00000000000000000000000000000000:1F90", "0A", 2001) <>
          line6("00000000000000000000000001000000:0BB8", "0A", 2002) <>
          line6("0000000000000000FFFF00000100007F:1F40", "0A", 2003) <>
          line6("000080FE000000000000000001000000:0016", "0A", 2004)

      assert Ports.parse(text) == [
               %{address: {0, 0, 0, 0, 0, 0, 0, 0}, port: 8080, inode: 2001},
               %{address: {0, 0, 0, 0, 0, 0, 0, 1}, port: 3000, inode: 2002},
               %{address: {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, port: 8000, inode: 2003},
               %{address: {0xFE80, 0, 0, 0, 0, 0, 0, 1}, port: 22, inode: 2004}
             ]
    end

    test "skips connections and other states" do
      text =
        @header <>
          line("0100007F:0FA0", "01", 1, "0100007F:C350") <>
          line("0100007F:0FA0", "06", 2, "0100007F:C351") <>
          line("0100007F:0FA0", "08", 3, "0100007F:C352") <>
          line("0100007F:0FA0", "0A", 4)

      assert [%{inode: 4}] = Ports.parse(text)
    end

    test "ignores lines it can't read, and empty input" do
      assert Ports.parse("") == []
      assert Ports.parse(@header) == []

      garbage =
        @header <>
          "nonsense\n" <>
          "   0: ZZZZZZZZ:0FA0 00000000:0000 0A 0 0 0 0 0 1\n" <>
          "   1: 0100007F:XYZW 00000000:0000 0A 0 0 0 0 0 1\n" <>
          "   2: 0100007F 00000000:0000 0A 0 0 0 0 0 1\n" <>
          "   3: 0100007F:0FA0 00000000:0000 0A 0 0 0 0 0 notanumber\n" <>
          "   4: 0100:0FA0 00000000:0000 0A 0 0 0 0 0 1\n" <>
          "   5: 0100007F:0000 00000000:0000 0A 0 0 0 0 0 1\n" <>
          line("0100007F:0FA0", "0A", 7)

      assert [%{port: 4000, inode: 7}] = Ports.parse(garbage)
    end
  end

  describe "reachable?/1" do
    # tailscaled runs in userspace mode and hands each connection from
    # the tailnet to 127.0.0.1 or ::1 on the same port.
    test "any-address and loopback listeners are" do
      for ip <- [
            {0, 0, 0, 0},
            {127, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0, 0},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ] do
        assert Ports.reachable?(ip), inspect(ip)
      end
    end

    test "other addresses aren't: tailscaled's own proxy, compose networks, link-local" do
      for ip <- [
            {127, 0, 0, 2},
            {127, 0, 0, 53},
            {172, 18, 0, 3},
            {100, 101, 102, 103},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 2},
            {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}
          ] do
        refute Ports.reachable?(ip), inspect(ip)
      end
    end
  end

  # A fake /proc entry: `fds` are symlink targets, as the kernel shows them.
  defp process(proc, pid, comm, fds) do
    dir = Path.join(proc, to_string(pid))
    File.mkdir_p!(Path.join(dir, "fd"))
    if comm, do: File.write!(Path.join(dir, "comm"), comm)

    for {target, fd} <- Enum.with_index(fds) do
      File.ln_s!(target, Path.join([dir, "fd", to_string(fd)]))
    end
  end

  defp tmp_proc do
    proc = Path.join(System.tmp_dir!(), "ports-proc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(proc)
    on_exit(fn -> File.rm_rf!(proc) end)
    proc
  end

  # Every inode the owner tests use.
  @any MapSet.new(1..5000)

  describe "owners/3" do
    test "only keeps the sockets it's asked about" do
      proc = tmp_proc()
      process(proc, 5, "srv\n", ["socket:[1]", "socket:[2]", "socket:[3]"])
      assert Ports.owners(proc, [5], MapSet.new([2])) == %{2 => "srv"}
    end

    test "stops reading fds past its budget, keeping what it found" do
      proc = tmp_proc()
      process(proc, 5, "first\n", ["socket:[1]"] ++ for(i <- 100..140, do: "pipe:[#{i}]"))
      process(proc, 6, "second\n", ["socket:[2]"])

      assert Ports.owners(proc, [5, 6], MapSet.new([1, 2]), 30) == %{}
      assert Ports.owners(proc, [5, 6], MapSet.new([1, 2]), 42) == %{1 => "first"}
      assert Ports.owners(proc, [5, 6], MapSet.new([1, 2]), 43) == %{1 => "first", 2 => "second"}
    end

    test "stops once every socket it's asked about has a name" do
      proc = tmp_proc()
      process(proc, 5, "srv\n", ["socket:[1]"])
      # Past the budget, but never reached.
      process(proc, 6, "other\n", for(i <- 1..50, do: "pipe:[#{i}]"))
      assert Ports.owners(proc, [5, 6], MapSet.new([1]), 1) == %{1 => "srv"}
    end

    test "maps socket inodes to the name of the lowest pid holding them" do
      proc = tmp_proc()
      process(proc, 1, "bash\n", ["/dev/null", "pipe:[5]"])

      process(proc, 57, "beam.smp\n", [
        "/dev/null",
        "socket:[1001]",
        "socket:[1002]",
        "anon_inode:[eventpoll]"
      ])

      process(proc, 91, "node\n", ["socket:[3003]"])
      process(proc, 90, "node\n", ["socket:[3003]"])

      assert Ports.owners(proc, [91, 1, 57, 90], @any) ==
               %{1001 => "beam.smp", 1002 => "beam.smp", 3003 => "node"}
    end

    test "only looks at the pids it's given" do
      proc = tmp_proc()
      process(proc, 5, "mine\n", ["socket:[1]"])
      process(proc, 6, "theirs\n", ["socket:[2]"])

      assert Ports.owners(proc, [5], @any) == %{1 => "mine"}
    end

    test "skips processes that are gone or unreadable" do
      proc = tmp_proc()
      process(proc, 5, "ok\n", ["socket:[1]"])
      # No comm: gone between listing its fds and reading its name.
      process(proc, 6, nil, ["socket:[2]"])
      # Another uid's fds can't be listed.
      File.mkdir_p!(Path.join(proc, "7"))
      File.write!(Path.join(proc, "7/comm"), "root-thing\n")

      assert Ports.owners(proc, [5, 6, 7, 8], @any) == %{1 => "ok"}
    end

    test "ignores fds that aren't sockets or don't parse" do
      proc = tmp_proc()
      process(proc, 5, "x\n", ["socket:[nope]", "socket:[12", "/tmp/socket:[3]", "socket:[4]"])
      assert Ports.owners(proc, [5], @any) == %{4 => "x"}
    end

    test "keeps names with spaces, and cleans what the environment could have planted" do
      proc = tmp_proc()
      process(proc, 5, "Web Content\n", ["socket:[1]"])
      process(proc, 6, "\e[31mred\n", ["socket:[2]"])
      process(proc, 7, String.duplicate("é", 40), ["socket:[3]"])
      process(proc, 8, "  \n", ["socket:[4]"])
      process(proc, 9, <<0xFF, 0xFE, ?\n>>, ["socket:[5]"])

      owners = Ports.owners(proc, [5, 6, 7, 8, 9], @any)

      assert owners[1] == "Web Content"
      assert owners[2] == "[31mred"
      assert owners[3] == String.duplicate("é", 32)
      refute Map.has_key?(owners, 4)
      assert owners[5] == "\uFFFD\uFFFD"

      for {_, name} <- owners do
        assert {:ok, _} =
                 ForemanProtocol.Event.new("box.ports", %{
                   environments: %{@e1 => [%{port: 1, process: name}]}
                 })
      end
    end
  end

  describe "collect/2" do
    setup do
      proc = tmp_proc()

      ctx = %{
        config: %Config{proc: proc},
        docker: DockerMock,
        log: fn _, _ -> :ok end
      }

      %{proc: proc, ctx: ctx}
    end

    defp container(id, env_id, opts \\ []) do
      %{
        "Id" => id,
        "State" => Keyword.get(opts, :state, "running"),
        "Labels" => %{
          "foreman.env_id" => env_id,
          "foreman.slug" => "a-1",
          "com.docker.compose.service" => Keyword.get(opts, :service, "app"),
          "foreman.devcontainer" =>
            if(Keyword.get(opts, :devcontainer, true), do: "true", else: "")
        }
      }
    end

    defp net(proc, pid, tcp, tcp6 \\ @header) do
      dir = Path.join([proc, to_string(pid), "net"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "tcp"), tcp)
      if tcp6, do: File.write!(Path.join(dir, "tcp6"), tcp6)
    end

    defp pids(map) do
      stub(DockerMock, :inspect_container, fn id ->
        case Map.fetch(map, id) do
          {:ok, pid} -> {:ok, %{"State" => %{"Pid" => pid, "Running" => pid > 0}}}
          :error -> {:error, {:http, 404, %{}}}
        end
      end)
    end

    defp top(map) do
      stub(DockerMock, :top, fn id ->
        case Map.fetch(map, id) do
          {:ok, pids} -> {:ok, pids}
          :error -> {:error, {:http, 404, %{}}}
        end
      end)
    end

    test "reports each running environment's reachable ports with their processes",
         %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn ["foreman.env_id"] ->
        {:ok,
         [
           container("aaa111aaa111", @e1),
           container("bbb222bbb222", @e1, service: "db", devcontainer: false),
           container("ccc333ccc333", @e2)
         ]}
      end)

      pids(%{"aaa111aaa111" => 4242, "ccc333ccc333" => 5151})

      net(
        proc,
        4242,
        @header <>
          line("0100007F:1388", "0A", 11) <>
          line("0200007F:041F", "0A", 12) <>
          line("0300120A:1538", "0A", 13) <>
          line("0100007F:1388", "01", 14, "0100007F:C350"),
        @header <> line6("00000000000000000000000000000000:0FA0", "0A", 15)
      )

      net(proc, 5151, @header)

      top(%{"aaa111aaa111" => [4242, 4300, 4301]})
      process(proc, 4300, "beam.smp\n", ["socket:[11]", "socket:[14]"])
      process(proc, 4301, "node\n", ["socket:[15]"])

      assert {report, _cache} = Ports.collect(ctx, %{})

      assert report == %{
               @e1 => [%{port: 4000, process: "node"}, %{port: 5000, process: "beam.smp"}],
               @e2 => []
             }

      assert {:ok, _} = ForemanProtocol.Event.new("box.ports", %{environments: report})
    end

    test "a port listening on both IPv4 and IPv6 is listed once", %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})

      net(
        proc,
        7,
        @header <> line("00000000:0FA0", "0A", 1),
        @header <>
          line6("00000000000000000000000000000000:0FA0", "0A", 2) <>
          line6("00000000000000000000000001000000:0FA0", "0A", 3)
      )

      top(%{"aaa111aaa111" => [9]})
      process(proc, 9, "vite\n", ["socket:[2]"])

      assert {%{@e1 => [%{port: 4000, process: "vite"}]}, _} = Ports.collect(ctx, %{})
    end

    test "without a name for a port, the port is listed on its own", %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})
      net(proc, 7, @header <> line("00000000:0FA0", "0A", 1) <> line("00000000:0FA1", "0A", 2))
      top(%{"aaa111aaa111" => [9]})
      process(proc, 9, "x\n", ["socket:[2]"])

      assert {%{@e1 => [%{port: 4000}, %{port: 4001, process: "x"}]}, _} =
               Ports.collect(ctx, %{})
    end

    test "only looks for names when the container's listeners change", %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})
      net(proc, 7, @header <> line("00000000:0FA0", "0A", 1))
      process(proc, 9, "one\n", ["socket:[1]"])

      expect(DockerMock, :top, fn "aaa111aaa111" -> {:ok, [9]} end)
      {first, cache} = Ports.collect(ctx, %{}, 0)
      {second, cache} = Ports.collect(ctx, cache, 1_000)
      assert first == second
      assert first == %{@e1 => [%{port: 4000, process: "one"}]}
      verify!()

      # Restarted on the same port: a new socket, so a new name.
      net(proc, 7, @header <> line("00000000:0FA0", "0A", 2))
      process(proc, 10, "two\n", ["socket:[2]"])

      expect(DockerMock, :top, fn "aaa111aaa111" -> {:ok, [10]} end)
      assert {%{@e1 => [%{port: 4000, process: "two"}]}, cache} = Ports.collect(ctx, cache, 2_000)
      verify!()

      # Same socket, but a minute on: looked up again, in case it changed
      # hands (a supervisor's socket passed to a new child).
      process(proc, 11, "three\n", ["socket:[2]"])
      {_, cache} = Ports.collect(ctx, cache, 59_000)
      expect(DockerMock, :top, fn "aaa111aaa111" -> {:ok, [11]} end)

      assert {%{@e1 => [%{port: 4000, process: "three"}]}, cache} =
               Ports.collect(ctx, cache, 62_000)

      verify!()

      # Nothing listening: nothing to name.
      net(proc, 7, @header)
      assert {%{@e1 => []}, _} = Ports.collect(ctx, cache, 63_000)
    end

    test "processes it can't read are cached as unnamed, not looked up every time",
         %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})
      net(proc, 7, @header <> line("00000000:0016", "0A", 1))
      # Root's: no readable fds.
      File.mkdir_p!(Path.join(proc, "9"))

      expect(DockerMock, :top, fn _ -> {:ok, [9]} end)
      {report, cache} = Ports.collect(ctx, %{}, 0)
      assert report == %{@e1 => [%{port: 22}]}
      assert {^report, _} = Ports.collect(ctx, cache, 30_000)
    end

    test "Docker failing to list processes doesn't stop the report, and is asked again",
         %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})
      net(proc, 7, @header <> line("00000000:0FA0", "0A", 1))
      process(proc, 9, "back\n", ["socket:[1]"])

      expect(DockerMock, :top, fn _ -> {:error, :timeout} end)
      {report, cache} = Ports.collect(ctx, %{})
      assert report == %{@e1 => [%{port: 4000}]}

      expect(DockerMock, :top, fn _ -> {:ok, [9]} end)
      assert {%{@e1 => [%{port: 4000, process: "back"}]}, _} = Ports.collect(ctx, cache)
    end

    test "leaves out stopped containers, non-devcontainers and malformed labels",
         %{ctx: ctx} do
      stray = %{
        "Id" => "ddd444ddd444",
        "State" => "running",
        "Labels" => %{"foreman.env_id" => "not-a-uuid", "foreman.devcontainer" => "true"}
      }

      bad_id = container("../../etc", @e2)

      stub(DockerMock, :list_containers, fn _ ->
        {:ok,
         [
           container("aaa111aaa111", @e1, state: "exited"),
           container("bbb222bbb222", @e1, devcontainer: false),
           stray,
           bad_id,
           %{"Id" => "eee555eee555", "State" => "running"}
         ]}
      end)

      stub(DockerMock, :inspect_container, fn id -> flunk("inspected #{id}") end)

      assert {report, _} = Ports.collect(ctx, %{})
      assert report == %{}
    end

    test "leaves out a container it can't read", %{ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ ->
        {:ok,
         [
           container("aaa111aaa111", @e1),
           container("bbb222bbb222", @e2),
           container("ccc333ccc333", "11111111-1111-4111-8111-111111111111")
         ]}
      end)

      # 0: stopped since the list. 9: no /proc entry (another pid
      # namespace). Gone between the list and the inspect.
      pids(%{"aaa111aaa111" => 0, "bbb222bbb222" => 9})

      assert {%{}, _} = Ports.collect(ctx, %{})
    end

    test "a kernel without IPv6 still reports IPv4", %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})
      net(proc, 7, @header <> line("00000000:0FA0", "0A", 1), nil)
      top(%{"aaa111aaa111" => []})

      assert {%{@e1 => [%{port: 4000}]}, _} = Ports.collect(ctx, %{})
    end

    test "Docker being down is an error, not an empty report", %{ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:error, :econnrefused} end)
      assert {:error, _} = Ports.collect(ctx, %{})
    end

    test "forgets containers that are gone", %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})
      net(proc, 7, @header <> line("00000000:0FA0", "0A", 1))
      top(%{"aaa111aaa111" => []})

      {_, cache} = Ports.collect(ctx, %{})
      assert Map.has_key?(cache, "aaa111aaa111")

      stub(DockerMock, :list_containers, fn _ -> {:ok, []} end)
      assert {report, cache} = Ports.collect(ctx, cache)
      assert report == %{}
      assert cache == %{}
    end

    test "caps a runaway list of ports", %{proc: proc, ctx: ctx} do
      stub(DockerMock, :list_containers, fn _ -> {:ok, [container("aaa111aaa111", @e1)]} end)
      pids(%{"aaa111aaa111" => 7})

      lines =
        for port <- 1000..1299, into: @header do
          hex = port |> Integer.to_string(16) |> String.pad_leading(4, "0")
          line("00000000:" <> hex, "0A", port)
        end

      net(proc, 7, lines)
      top(%{"aaa111aaa111" => []})

      assert {%{@e1 => ports}, _} = Ports.collect(ctx, %{})
      assert length(ports) == 100
      assert hd(ports).port == 1000
    end
  end
end
