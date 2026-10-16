defmodule ForemanAgent.HandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{DockerMock, Handler, RunnerMock}
  alias ForemanProtocol.Command

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

  test "a crash in an environment command comes back as a redacted error" do
    secret = "sk_live_0123456789abcdef"
    boom = fn _, _, _ -> raise "couldn't use #{secret}" end
    stub(RunnerMock, :run, boom)
    stub(DockerMock, :list_containers, fn _ -> raise "couldn't use #{secret}" end)

    {:ok, cmd} =
      Command.new("env.restart", %{
        env_id: "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f",
        slug: "web-1",
        mode: "all",
        compose_env: %{"STRIPE_KEY" => secret}
      })

    assert {:error, message} = Handler.handle(cmd, fn _, _ -> :ok end)
    assert message =~ "operation crashed"
    refute message =~ secret
  end
end
