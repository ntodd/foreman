defmodule ForemanAgent.Integration.ComposePolicyTest do
  @moduledoc """
  The policy against what the real `docker compose config` emits, for the
  compose features that change what it shows: env files (inlined unless
  the agent asks it not to) and profiles (left out unless enabled). Needs
  the Docker CLI with the compose plugin, but no daemon; git and the
  devcontainer CLI are stubbed. Compose versions differ in what they
  show, so FOREMAN_TEST_COMPOSE can name a standalone compose binary to
  run instead of the plugin.

      mix test --only docker test/integration/compose_policy_test.exs
      FOREMAN_TEST_COMPOSE=/path/to/docker-compose mix test --only docker ...
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

  # A box whose default Docker runtime is runc.
  setup do
    stub(DockerMock, :info, fn -> {:ok, %{"DefaultRuntime" => "runc"}} end)
    stub(DockerMock, :list_networks, fn _ -> {:ok, []} end)
    stub(DockerMock, :list_containers, fn _ -> {:ok, []} end)
    :ok
  end

  setup %{tmp_dir: tmp} do
    config = %Config{
      data_dir: Path.join(tmp, "data"),
      envs_root: Path.join(tmp, "envs"),
      secrets_root: Path.join(tmp, "run"),
      release_root: Path.join(tmp, "opt"),
      feature_dir: Path.expand("../../../../features/src/foreman", __DIR__),
      policy_rules: Policy.default_rules(),
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
  defp stub_tools(devcontainer, compose_yaml, extra \\ %{}) do
    test_pid = self()

    stub(RunnerMock, :run, fn command, args, opts ->
      case {command, args} do
        # Listing connect hooks: there are none.
        {"docker", ["exec", "-u", _, "-w", _, _container, "sh", "-c", _]} ->
          {:ok, %{status: 0, output: ""}}

        {"git", args} ->
          dest = List.last(args)
          File.mkdir_p!(Path.join(dest, ".git/info"))
          File.mkdir_p!(Path.join(dest, ".devcontainer"))
          File.write!(Path.join(dest, ".devcontainer/devcontainer.json"), devcontainer)
          File.write!(Path.join(dest, ".devcontainer/docker-compose.yml"), compose_yaml)
          for {rel, content} <- extra, do: File.write!(Path.join(dest, rel), content)
          {:ok, %{status: 0, output: ""}}

        {"docker", ["compose" | rest]} ->
          send(test_pid, {:compose, rest})
          env = System.get_env() |> Map.merge(opts[:env] || %{}) |> Map.delete("DOCKER_HOST")

          {out, status} =
            case System.get_env("FOREMAN_TEST_COMPOSE") do
              nil -> System.cmd("docker", args, env: Enum.to_list(env), stderr_to_stdout: true)
              compose -> System.cmd(compose, rest, env: Enum.to_list(env), stderr_to_stdout: true)
            end

          {:ok, %{status: status, output: out}}

        {"devcontainer", ["read-configuration" | _]} ->
          resolved = %{
            "configuration" => %{},
            "mergedConfiguration" => %{},
            "featuresConfiguration" => %{
              "featureSets" => [
                %{
                  "sourceInformation" => %{"userFeatureId" => "./.foreman/feature"},
                  "features" => [%{"id" => "foreman"}]
                }
              ]
            }
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

  # Without interpolation compose leaves env_file alone, but then a path
  # built from variables (which a repo's .env sets) can't be checked.
  test "an env_file path built from variables is refused", %{ctx: ctx, config: config} do
    other = Path.join([config.secrets_root, @other_env_id, "secrets.env"])

    stub_tools(
      @devcontainer,
      "services:\n  app:\n    image: alpine\n    env_file: ${NOPE:-#{other}}\n"
    )

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "env_file"
    refute_received :up
  end

  test "an env_file compose can't parse doesn't echo it anywhere", %{ctx: ctx, config: config} do
    identity = Path.join(config.data_dir, "identity.json")
    stub_tools(@devcontainer, "services:\n  app:\n    image: alpine\n    env_file: #{identity}\n")

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "a protected path"
    refute message <> logged() =~ "QUdFTlRfUFJJVkFURV9LRVk="
  end

  # Compose reads these while it parses, before its output shows anything
  # a check of the config could catch, so they're refused before compose
  # runs at all.
  test "an include's env_file holding another environment's secrets", %{ctx: ctx, config: config} do
    other = Path.join([config.secrets_root, @other_env_id, "secrets.env"])

    stub_tools(@devcontainer, "include:\n  - path: inc.yml\n    env_file: #{other}\n", %{
      ".devcontainer/inc.yml" =>
        "services:\n  app:\n    image: alpine\n    environment:\n      STOLEN: ${OTHER_DATABASE_URL}\n"
    })

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "env_file #{other}"
    refute_received {:compose, _}
    refute_received :up
  end

  test "a label_file can't quote the agent's key", %{ctx: ctx, config: config} do
    identity = Path.join(config.data_dir, "identity.json")

    stub_tools(
      @devcontainer,
      "services:\n  app:\n    image: alpine\n    label_file: #{identity}\n"
    )

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "label_file"
    refute message <> logged() =~ "QUdFTlRfUFJJVkFURV9LRVk="
    refute_received {:compose, _}
  end

  @pinch """
  services:
    app:
      image: alpine
      deploy:
        resources:
          reservations:
            devices:
              - driver: nvidia
                count: all
                capabilities: [gpu, compute, video, utility]
  """

  test "an NVIDIA GPU reservation is the gpu rule's", %{ctx: ctx, config: config} do
    stub_tools(@devcontainer, @pinch)

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "FOREMAN_POLICY=gpu=allow"
    refute_received :up

    ctx = put_in(ctx.config.policy_rules, Map.put(config.policy_rules, :gpu, :allow))
    assert {:ok, _} = Env.run("env.create", payload(), ctx)
    assert_received :up
  end

  test "gpus: all leaves the capabilities to the image, so gpu=allow doesn't cover it", %{
    ctx: ctx,
    config: config
  } do
    stub_tools(@devcontainer, "services:\n  app:\n    image: alpine\n    gpus: all\n")
    ctx = put_in(ctx.config.policy_rules, Map.put(config.policy_rules, :gpu, :allow))

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "host devices"
    refute_received :up
  end

  test "use_api_socket is the Docker socket", %{ctx: ctx} do
    stub_tools(@devcontainer, "services:\n  app:\n    image: alpine\n    use_api_socket: true\n")

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "Docker socket"
    refute_received :up
  end

  test "a provider service is refused", %{ctx: ctx} do
    stub_tools(
      @devcontainer,
      "services:\n  app:\n    image: alpine\n  p:\n    provider:\n      type: ./evil\n"
    )

    assert {:error, message} = Env.run("env.create", payload(), ctx)
    assert message =~ "provider"
    refute_received :up
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

  # The box's firewall knows environment traffic by its bridge, so what
  # compose really merges has to put every network on one, including a
  # network the repo named a bridge for itself.
  test "every network the environment uses is on a Foreman bridge", %{ctx: ctx, config: config} do
    stub_tools(@devcontainer, """
    services:
      app:
        image: alpine
        networks: [default, back]
      db:
        image: postgres
        networks: [back]
      tools:
        image: alpine
        profiles: ["tools"]
        networks: [debug]
    networks:
      back:
        driver_opts:
          com.docker.network.bridge.name: docker0
      debug: {}
    """)

    assert {:ok, _} = Env.run("env.create", payload(), ctx)

    [repo_file] =
      Path.wildcard(Path.join([config.envs_root, @env_id, "**/docker-compose.yml"]),
        match_dot: true
      )

    overlay = Path.join([config.envs_root, @env_id, "meta/overlay.yml"])

    {out, 0} =
      System.cmd(
        "docker",
        ~w(compose -p storefront-2 --profile * -f #{repo_file} -f #{overlay} config --format json),
        stderr_to_stdout: true
      )

    networks = JSON.decode!(out)["networks"]
    assert Enum.sort(Map.keys(networks)) == ["back", "debug", "default"]

    for {key, spec} <- networks do
      bridge = spec["driver_opts"]["com.docker.network.bridge.name"]
      assert bridge == Env.Overlay.bridge_name(@env_id, spec["name"]), key
    end
  end
end
