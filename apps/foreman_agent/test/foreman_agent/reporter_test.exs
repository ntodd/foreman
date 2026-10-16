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
end
