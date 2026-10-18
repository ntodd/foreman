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

  @tag :tmp_dir
  test "a refused pull's message is redacted too, and keeps its result", %{tmp_dir: tmp} do
    secret = "sk_live_0123456789abcdef"
    env_id = "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
    previous = ForemanAgent.Config.get()
    on_exit(fn -> ForemanAgent.Config.put(previous) end)

    config = %{
      previous
      | envs_root: Path.join(tmp, "envs"),
        secrets_root: Path.join(tmp, "run"),
        data_dir: Path.join(tmp, "data")
    }

    ForemanAgent.Config.put(config)

    # An environment that has come up before: its clone and saved spec.
    meta = Path.join([config.envs_root, env_id, "meta"])
    File.mkdir_p!(Path.join([config.envs_root, env_id, "workspace", "web", ".git"]))
    File.mkdir_p!(meta)

    File.write!(
      Path.join(meta, "spec.term"),
      :erlang.term_to_binary(%{
        env_id: env_id,
        slug: "web-1",
        repo: "acme/web",
        devcontainer_service: "app",
        remote_user: "vscode",
        remote_workspace_folder: "/workspaces/web"
      })
    )

    stub(DockerMock, :list_containers, fn _ ->
      {:ok,
       [
         %{
           "Id" => "c1",
           "State" => "running",
           "Labels" => %{"com.docker.compose.service" => "app"}
         }
       ]}
    end)

    # Whatever runs in the environment answers for its git.
    stub(RunnerMock, :run, fn "docker", ["exec" | _], _ ->
      {:ok, %{status: 0, output: secret <> "\n"}}
    end)

    {:ok, cmd} =
      Command.new("env.rebuild", %{
        env_id: env_id,
        slug: "web-1",
        repo: "acme/web",
        clone_url: "https://github.com/acme/web.git",
        branch: "main",
        pull: true,
        compose_env: %{"STRIPE_KEY" => secret}
      })

    assert {:error, message, %{"pull_failed" => true}} = Handler.handle(cmd, fn _, _ -> :ok end)
    assert message =~ "checked out, not main"
    refute message =~ secret
  end
end
