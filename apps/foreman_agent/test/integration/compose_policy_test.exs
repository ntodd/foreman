defmodule ForemanAgent.Integration.ComposePolicyTest do
  @moduledoc """
  The policy against what the real `docker compose config` emits, for the
  compose features that change what it shows: env files (inlined unless
  the agent asks it not to) and profiles (left out unless enabled). Needs
  the Docker CLI with the compose plugin, but no daemon; git and the
  devcontainer CLI are stubbed.

      mix test --only docker test/integration/compose_policy_test.exs
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{Config, DockerMock, Env, RunnerMock}
  alias ForemanAgent.Env.Policy

  @moduletag :docker
  @moduletag :tmp_dir
  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @other_env_id "11111111-2222-3333-4444-555555555555"

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    config = %Config{
      data_dir: Path.join(tmp, "data"),
      envs_root: Path.join(tmp, "envs"),
      secrets_root: Path.join(tmp, "run"),
      release_root: Path.join(tmp, "opt"),
      feature_dir: Path.expand("../../../../features/src/foreman", __DIR__),
      policy_rules: Policy.default_rules(),
      tun_device: false,
      docker_socket: "/var/run/docker.sock"
    }

    for dir <- [config.envs_root, config.secrets_root, config.data_dir],
        do: File.mkdir_p!(dir)

    # The agent's key, as Identity.save/2 writes it: one line of JSON.
    File.write!(
      Path.join(config.data_dir, "identity.json"),
      ~s({"agent_id":"a1","private_key":"QUdFTlRfUFJJVkFURV9LRVk="})
    )

    other = Path.join(config.secrets_root, @other_env_id)
    File.mkdir_p!(other)

    File.write!(
      Path.join(other, "secrets.env"),
      "export OTHER_DATABASE_URL='postgres://u:p@h/db'\n"
    )

    test_pid = self()
    log = fn _stream, data -> send(test_pid, {:log, data}) end

    %{config: config, ctx: %{config: config, runner: RunnerMock, docker: DockerMock, log: log}}
  end

  # Real `docker compose`; everything else stubbed.
  defp stub_tools(devcontainer, compose_yaml) do
    test_pid = self()

    stub(RunnerMock, :run, fn command, args, opts ->
      case {command, args} do
        {"git", args} ->
          dest = List.last(args)
          File.mkdir_p!(Path.join(dest, ".git/info"))
          File.mkdir_p!(Path.join(dest, ".devcontainer"))
          File.write!(Path.join(dest, ".devcontainer/devcontainer.json"), devcontainer)
          File.write!(Path.join(dest, ".devcontainer/docker-compose.yml"), compose_yaml)
          {:ok, %{status: 0, output: ""}}

        {"docker", ["compose" | _]} ->
          env = System.get_env() |> Map.merge(opts[:env] || %{}) |> Map.delete("DOCKER_HOST")

          {out, status} =
            System.cmd("docker", args, env: Enum.to_list(env), stderr_to_stdout: true)

          {:ok, %{status: status, output: out}}

        {"devcontainer", ["read-configuration" | _]} ->
          resolved = %{
            "configuration" => %{},
            "mergedConfiguration" => %{},
            "featuresConfiguration" => %{"featureSets" => []}
          }

          {:ok, %{status: 0, output: JSON.encode!(resolved) <> "\n"}}

        {"devcontainer", ["up" | _]} ->
          send(test_pid, :up)

          {:ok,
           %{
             status: 0,
             output:
               ~s({"outcome":"success","containerId":"c1","remoteUser":"root","remoteWorkspaceFolder":"/w"}\n)
           }}
      end
    end)
  end

  defp payload do
    {:ok, cmd} =
      ForemanProtocol.Command.new("env.create", %{
        "env_id" => @env_id,
        "slug" => "storefront-2",
        "repo" => "acme/storefront",
        "clone_url" => "https://github.com/acme/storefront.git",
        "branch" => "main",
        "tailscale" => %{"enabled" => false}
      })

    cmd.payload
  end

  @devcontainer ~s({"dockerComposeFile": "docker-compose.yml", "service": "app"})

  test "an env_file holding another environment's secrets is refused", %{ctx: ctx, config: config} do
    other = Path.join([config.secrets_root, @other_env_id, "secrets.env"])
    stub_tools(@devcontainer, "services:\n  app:\n    image: alpine\n    env_file: #{other}\n")

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "env_file #{other}"
    refute_received :up
  end

  test "an env_file compose can't parse doesn't echo it anywhere", %{ctx: ctx, config: config} do
    identity = Path.join(config.data_dir, "identity.json")
    stub_tools(@devcontainer, "services:\n  app:\n    image: alpine\n    env_file: #{identity}\n")

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "a protected path"
    refute message <> logged() =~ "QUdFTlRfUFJJVkFURV9LRVk="
  end

  defp logged do
    receive do
      {:log, data} -> data <> logged()
    after
      0 -> ""
    end
  end

  test "a privileged service behind a profile, named in runServices, is refused", %{ctx: ctx} do
    devcontainer =
      ~s({"dockerComposeFile": "docker-compose.yml", "service": "app", "runServices": ["app", "debug"]})

    stub_tools(devcontainer, """
    services:
      app:
        image: alpine
      debug:
        image: alpine
        profiles: ["debug"]
        privileged: true
        volumes:
          - /:/host
    """)

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "service 'debug' runs privileged"
    refute_received :up
  end

  test "a profiled service gets the overlay like any other", %{ctx: ctx, config: config} do
    stub_tools(@devcontainer, """
    services:
      app:
        image: alpine
      tools:
        image: alpine
        profiles: ["tools"]
        ports: ["2222:22"]
    """)

    assert {:ok, %{"services" => ["app", "tools"]}} = Env.run("env.create", payload(), ctx)
    overlay = File.read!(Path.join([config.envs_root, @env_id, "meta/overlay.yml"]))
    assert overlay =~ ~s("tools":)
  end
end
