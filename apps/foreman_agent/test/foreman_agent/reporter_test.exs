defmodule ForemanAgent.ReporterTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{DockerMock, Reporter, RunnerMock}

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

    refute_receive {:DOWN, ^ref, _, _, _}, 500
    assert Process.alive?(pid)
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
end
