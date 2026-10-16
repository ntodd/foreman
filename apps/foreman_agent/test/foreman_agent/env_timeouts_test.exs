defmodule ForemanAgent.EnvTimeoutsTest do
  @moduledoc """
  Every command an environment operation runs has a timeout, so a hung
  docker, compose or git can't hold the environment's queue forever, and
  a command that runs out of time says so.
  """
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, Env, RunnerMock}
  alias ForemanAgent.Env.Policy

  @moduletag :tmp_dir
  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    config = %Config{
      data_dir: Path.join(tmp, "data"),
      envs_root: Path.join(tmp, "envs"),
      secrets_root: Path.join(tmp, "run"),
      release_root: Path.join(tmp, "opt"),
      policy_rules: Policy.default_rules(),
      tun_device: true,
      docker_socket: "/var/run/docker.sock"
    }

    log = fn _stream, _data -> :ok end
    %{ctx: %{config: config, runner: RunnerMock, docker: DockerMock, log: log}}
  end

  defp payload(command, extra \\ %{}) do
    {:ok, cmd} =
      ForemanProtocol.Command.new(
        command,
        Map.merge(%{"env_id" => @env_id, "slug" => "storefront-2"}, extra)
      )

    cmd.payload
  end

  test "stop runs compose with a timeout", %{ctx: ctx} do
    expect(RunnerMock, :run, fn _docker, ["compose", "-p", "storefront-2", "stop"], opts ->
      assert is_integer(opts[:timeout]) and opts[:timeout] > 0
      {:ok, %{status: 0, output: ""}}
    end)

    assert {:ok, _} = Env.run("env.stop", payload("env.stop"), ctx)
  end

  test "a stop that runs out of time says it timed out", %{ctx: ctx} do
    expect(RunnerMock, :run, fn _, _, _ -> {:ok, %{status: :timeout, output: "Stopping app"}} end)

    assert {:error, message} = Env.run("env.stop", payload("env.stop"), ctx)
    assert message =~ "timed out"
  end

  test "logs run with a timeout, and a timeout says so", %{ctx: ctx} do
    expect(RunnerMock, :run, fn _docker, args, opts ->
      assert "logs" in args
      assert is_integer(opts[:timeout]) and opts[:timeout] > 0
      {:ok, %{status: :timeout, output: ""}}
    end)

    assert {:error, message} = Env.run("env.logs", payload("env.logs"), ctx)
    assert message =~ "docker compose logs timed out"
  end

  test "a stop that times out is named for what it was doing", %{ctx: ctx} do
    expect(RunnerMock, :run, fn _, _, _ -> {:ok, %{status: :timeout, output: ""}} end)

    assert {:error, message} = Env.run("env.stop", payload("env.stop"), ctx)
    assert message =~ "docker compose stop timed out after 30 minutes"
  end

  test "a clone gets an hour, and a clone that times out says it was the clone", %{ctx: ctx} do
    {:ok, cmd} =
      ForemanProtocol.Command.new("env.create", %{
        "env_id" => @env_id,
        "slug" => "storefront-2",
        "repo" => "acme/storefront",
        "clone_url" => "https://github.com/acme/storefront.git",
        "branch" => "main",
        "tailscale" => %{"enabled" => true}
      })

    stub(RunnerMock, :run, fn _cmd, args, opts ->
      if "clone" in args do
        assert opts[:timeout] == :timer.minutes(60)
        {:ok, %{status: :timeout, output: ""}}
      else
        {:ok, %{status: 0, output: ""}}
      end
    end)

    assert {:error, message} = Env.run("env.create", cmd.payload, ctx)
    assert message =~ "git clone timed out after 60 minutes"
    refute message =~ "git -c"
  end
end
