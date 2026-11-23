defmodule ForemanAgent.ReporterTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{DockerMock, Reporter, RunnerMock}

  alias ForemanAgent.VM.Machine.Cloud

  setup :set_mox_global

  setup do
    previous =
      {Application.get_env(:foreman_agent, :runner), Application.get_env(:foreman_agent, :docker)}

    Application.put_env(:foreman_agent, :runner, RunnerMock)
    Application.put_env(:foreman_agent, :docker, DockerMock)

    on_exit(fn ->
      {runner, docker} = previous
      restore(:runner, runner)
      restore(:docker, docker)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:foreman_agent, key)
  defp restore(key, value), do: Application.put_env(:foreman_agent, key, value)

  test "box polling checks multiple units in one call and keeps their states in order" do
    ids = Enum.map(1..4, fn _ -> ForemanProtocol.uuid() end)
    args = ["is-active" | Enum.map(ids, &Cloud.unit/1)]

    expect(RunnerMock, :run, fn "systemctl", ^args, _ ->
      {:ok, %{status: 0, output: "inactive\nactive\nfailed\nreloading\n"}}
    end)

    assert Cloud.running(ids, nil) == [Enum.at(ids, 1), Enum.at(ids, 3)]
    assert Cloud.running([], nil) == []
    verify!()
  end

  test "workspace samples distinguish running containers in a partial project from an unreachable guest" do
    entries = [
      %{
        env_id: "partial",
        state: "partial",
        containers: [%{id: "app", state: "running"}, %{id: "db", state: "exited"}]
      },
      %{env_id: "offline", state: "stopped", containers: []},
      %{env_id: "unreachable", state: "partial", containers: []}
    ]

    assert Reporter.running_containers(entries) == %{"partial" => ["app"], "offline" => []}
  end

  test "only a systemd OOM result supplies an exit time" do
    id = "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

    args = [
      "show",
      "--property=ActiveState,Result,ExecMainExitTimestamp",
      "foreman-vm-#{id}.service"
    ]

    for {result, expected} <- [
          {"oom-kill", {:oom_kill, 1_735_689_600}},
          {"signal", :stopped},
          {"success", :stopped}
        ] do
      expect(RunnerMock, :run, fn "systemctl", ^args, opts ->
        assert opts[:env]["TZ"] == "UTC"

        {:ok,
         %{
           status: 0,
           output: "ExecMainExitTimestamp=Wed 2025-01-01 00:00:00 UTC\nResult=#{result}\n"
         }}
      end)

      assert Cloud.inventory_state(id, nil) == expected
    end

    verify!()
  end

  test "keeps running when collecting metrics, stats or inventory raises" do
    stub(RunnerMock, :run, fn _cmd, _args, _opts -> :erlang.error(:eagain) end)
    stub(DockerMock, :list_containers, fn _ -> raise "docker went away" end)
    stub(DockerMock, :info, fn -> raise "docker went away" end)

    pid = start_supervised!(Reporter)
    ref = Process.monitor(pid)

    # The first metrics sample runs straight away; force the rest.
    Reporter.report_now()
    send(pid, :stats)
    send(pid, :metrics)
    send(pid, :ports)

    refute_receive {:DOWN, ^ref, _, _, _}, 500
    assert Process.alive?(pid)
  end

  describe "listening ports" do
    @e1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
    @header "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

    setup do
      proc = Path.join(System.tmp_dir!(), "reporter-ports-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(proc, "77/net"))
      previous = ForemanAgent.Config.get()
      # Ports read from Docker, as the agent in a VM reads them; the box's
      # own come from its VMs (ForemanAgent.VMEnvTest).
      ForemanAgent.Config.put(%{previous | proc: proc, mode: :guest})

      stub(RunnerMock, :run, fn _cmd, _args, _opts -> {:ok, %{status: 0, output: ""}} end)
      stub(DockerMock, :info, fn -> {:ok, %{}} end)

      stub(DockerMock, :list_containers, fn _ ->
        {:ok,
         [
           %{
             "Id" => "aaa111aaa111",
             "State" => "running",
             "Labels" => %{
               "foreman.env_id" => @e1,
               "foreman.slug" => "a-1",
               "foreman.devcontainer" => "true"
             }
           }
         ]}
      end)

      stub(DockerMock, :inspect_container, fn _ -> {:ok, %{"State" => %{"Pid" => 77}}} end)
      stub(DockerMock, :stats, fn _ -> {:error, :gone} end)
      stub(DockerMock, :top, fn _ -> {:ok, []} end)
      listen(proc, [])

      :ok = ForemanAgent.Outbox.attach(self())
      _ = ports_events()

      on_exit(fn ->
        ForemanAgent.Config.put(previous)
        File.rm_rf!(proc)
      end)

      %{proc: proc}
    end

    defp listen(proc, ports) do
      lines =
        for port <- ports, into: @header do
          hex = port |> Integer.to_string(16) |> String.pad_leading(4, "0")

          "   0: 00000000:#{hex} 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 #{port} 1\n"
        end

      File.write!(Path.join(proc, "77/net/tcp"), lines)
    end

    defp ports_events do
      receive do
        {:outbox_deliver, %{type: "box.ports", payload: payload}, _} -> [payload | ports_events()]
        {:outbox_deliver, _, _} -> ports_events()
      after
        200 -> []
      end
    end

    test "are reported after a join, then only when they change", %{proc: proc} do
      pid = start_supervised!(Reporter)

      Reporter.report_now()
      assert [%{environments: %{@e1 => []}}] = ports_events()

      send(pid, :ports)
      assert ports_events() == []

      listen(proc, [5000])
      send(pid, :ports)
      assert [%{environments: %{@e1 => [%{port: 5000}]}}] = ports_events()

      send(pid, :ports)
      assert ports_events() == []

      # The control plane may have restarted and forgotten; a join resends.
      Reporter.report_now()
      assert [%{environments: %{@e1 => [%{port: 5000}]}}] = ports_events()

      listen(proc, [])
      send(pid, :ports)
      assert [%{environments: %{@e1 => []}}] = ports_events()
    end

    # A control plane that lost them without the agent rejoining (its
    # store restarted) has them back within a minute.
    test "are sent again every minute even when they haven't changed", %{proc: proc} do
      pid = start_supervised!(Reporter)
      listen(proc, [5000])
      Reporter.report_now()
      assert [%{environments: %{@e1 => [%{port: 5000}]}}] = ports_events()

      send(pid, :ports)
      assert ports_events() == []

      :sys.replace_state(pid, &%{&1 | ports_sent_at: &1.ports_sent_at - 60_000})
      send(pid, :ports)
      assert [%{environments: %{@e1 => [%{port: 5000}]}}] = ports_events()

      send(pid, :ports)
      assert ports_events() == []
    end

    test "Docker going away skips a report rather than sending an empty one" do
      pid = start_supervised!(Reporter)
      Reporter.report_now()
      _ = ports_events()

      stub(DockerMock, :list_containers, fn _ -> {:error, :econnrefused} end)
      send(pid, :ports)
      assert ports_events() == []
      assert Process.alive?(pid)
    end
  end

  describe "kills inside a VM" do
    @e1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

    setup do
      tmp = Path.join(System.tmp_dir!(), "reporter-oom-#{System.unique_integer([:positive])}")
      previous = ForemanAgent.Config.get()
      config = %{previous | mode: :host, vm_root: Path.join(tmp, "vms")}
      ForemanAgent.Config.put(config)

      File.mkdir_p!(ForemanAgent.VM.paths(config, @e1).dir)
      ForemanAgent.VM.write_meta(config, @e1, %{"slug" => "a-1"})
      serial = ForemanAgent.VM.paths(config, @e1).serial
      File.write!(serial, "[    0.000000] Linux version 6.8.0\r\n")

      stub(RunnerMock, :run, fn _cmd, _args, _opts -> {:ok, %{status: 0, output: ""}} end)
      :ok = ForemanAgent.Outbox.attach(self())
      _ = oom_events()

      on_exit(fn ->
        ForemanAgent.Config.put(previous)
        File.rm_rf!(tmp)
      end)

      %{serial: serial}
    end

    defp oom_events do
      receive do
        {:outbox_deliver, %{type: "box.guest_oom", payload: payload}, _} ->
          [payload | oom_events()]

        {:outbox_deliver, _, _} ->
          oom_events()
      after
        200 -> []
      end
    end

    test "are reported once, with when the box saw them", %{serial: serial} do
      pid = start_supervised!(Reporter)
      send(pid, :guest_oom)
      assert oom_events() == []

      File.write!(
        serial,
        "[ 99.000000] Out of memory: Killed process 4321 (orca) total-vm:1kB, anon-rss:1kB\r\n",
        [:append]
      )

      before = System.os_time(:second)
      send(pid, :guest_oom)
      assert [%{environments: %{@e1 => %{at: at, processes: ["orca"]}}}] = oom_events()
      assert at in before..(before + 5)

      send(pid, :guest_oom)
      assert oom_events() == []
    end
  end

  describe "the box firewall" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "reporter-fw-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      previous = ForemanAgent.Config.get()

      ForemanAgent.Config.put(%{
        previous
        | firewall_marker: Path.join(tmp, "loaded"),
          firewall_info: Path.join(tmp, "info"),
          firewall_rules: Path.join(tmp, "rules")
      })

      File.write!(Path.join(tmp, "rules"), "table inet foreman {}\n")
      stub(RunnerMock, :run, fn _cmd, _args, _opts -> {:ok, %{status: 0, output: ""}} end)
      stub(DockerMock, :list_containers, fn _ -> {:ok, []} end)
      stub(DockerMock, :info, fn -> {:ok, %{}} end)
      # The outbox is the app's, and may hold events from other tests.
      :ok = ForemanAgent.Outbox.attach(self())
      _ = firewall_events()

      on_exit(fn ->
        ForemanAgent.Config.put(previous)
        File.rm_rf!(tmp)
      end)

      %{tmp: tmp}
    end

    defp firewall_events do
      receive do
        {:outbox_deliver, %{type: "box.firewall", payload: payload}, _} ->
          [payload | firewall_events()]

        {:outbox_deliver, _, _} ->
          firewall_events()
      after
        200 -> []
      end
    end

    # After every join, so the control plane's copy can't drift from the
    # join's even when the firewall changed and changed back in between.
    test "is reported after a join, and when it changes", %{tmp: tmp} do
      pid = start_supervised!(Reporter)
      Reporter.report_now()
      assert [%{firewall: "missing"}] = firewall_events()

      send(pid, :inventory)
      assert firewall_events() == []

      File.write!(Path.join(tmp, "loaded"), "source_sha256=x\n")
      send(pid, :inventory)
      assert [%{firewall: "outdated"}] = firewall_events()

      Reporter.report_now()
      assert [%{firewall: "outdated"}] = firewall_events()
    end
  end

  describe "whether the box needs a reboot" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "reporter-reboot-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      previous = ForemanAgent.Config.get()

      ForemanAgent.Config.put(%{
        previous
        | reboot_required: Path.join(tmp, "reboot-required"),
          livepatch_dir: Path.join(tmp, "livepatch")
      })

      stub(RunnerMock, :run, fn _cmd, _args, _opts -> {:ok, %{status: 0, output: ""}} end)
      stub(DockerMock, :list_containers, fn _ -> {:ok, []} end)
      stub(DockerMock, :info, fn -> {:ok, %{}} end)
      :ok = ForemanAgent.Outbox.attach(self())
      _ = reboot_events()

      on_exit(fn ->
        ForemanAgent.Config.put(previous)
        File.rm_rf!(tmp)
      end)

      %{tmp: tmp}
    end

    defp reboot_events do
      receive do
        {:outbox_deliver, %{type: "box.reboot", payload: payload}, _} ->
          [payload | reboot_events()]

        {:outbox_deliver, _, _} ->
          reboot_events()
      after
        200 -> []
      end
    end

    test "is reported after a join, and when it changes", %{tmp: tmp} do
      pid = start_supervised!(Reporter)
      Reporter.report_now()
      assert [%{required: false}] = reboot_events()

      send(pid, :inventory)
      assert reboot_events() == []

      File.write!(Path.join(tmp, "reboot-required"), "*** System restart required ***\n")
      File.write!(Path.join(tmp, "reboot-required.pkgs"), "libc6\n")
      send(pid, :inventory)
      assert [%{required: true, packages: ["libc6"]}] = reboot_events()

      Reporter.report_now()
      assert [%{required: true}] = reboot_events()
    end
  end
end
