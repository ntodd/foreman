defmodule ForemanAgent.Integration.EnvDockerTest do
  @moduledoc """
  Runs the agent's environment operations against a real Docker daemon and
  the real devcontainer CLI. Slow (it builds images); run with:

      mix test --only docker

  Needs Docker, git and the devcontainer CLI (FOREMAN_DEVCONTAINER_CLI, or
  ../../.tools/node_modules/.bin/devcontainer).
  """
  use ExUnit.Case, async: false

  alias ForemanAgent.{Config, Env}
  alias ForemanAgent.Docker.Engine
  alias ForemanAgent.Test.GitServer

  @moduletag :docker
  @moduletag timeout: 900_000

  @env1 "11111111-1111-4111-8111-111111111111"
  @env2 "22222222-2222-4222-8222-222222222222"

  setup_all do
    root = Path.expand("../../tmp/docker-test", __DIR__)
    File.rm_rf!(root)
    File.mkdir_p!(root)

    base_url = GitServer.start(Path.join(root, "git"), ["hello", "sneaky", "innocent"])

    config = %Config{
      data_dir: Path.join(root, "data"),
      envs_root: Path.join(root, "envs"),
      secrets_root: Path.join(root, "run"),
      release_root: Path.join(root, "opt"),
      devcontainer:
        System.get_env("FOREMAN_DEVCONTAINER_CLI") ||
          Path.expand("../../../../.tools/node_modules/.bin/devcontainer", __DIR__),
      docker_socket: docker_socket(),
      allowed_git_hosts: ["127.0.0.1"],
      insecure_git_hosts: ["127.0.0.1"],
      policy_rules: Env.Policy.default_rules(),
      feature_dir: Path.expand("../../../../features/src/foreman", __DIR__),
      tun_device: true
    }

    File.mkdir_p!(config.envs_root)
    File.mkdir_p!(config.secrets_root)
    Config.put(config)

    on_exit(fn ->
      for slug <- ["hello-1", "hello-2"] do
        System.cmd("docker", ["compose", "-p", slug, "down", "--volumes", "--remove-orphans"],
          stderr_to_stdout: true
        )
      end
    end)

    %{config: config, base_url: base_url}
  end

  defp docker_socket do
    case System.get_env("DOCKER_HOST") do
      "unix://" <> path ->
        path

      _ ->
        Enum.find(
          ["/var/run/docker.sock", Path.expand("~/.docker/run/docker.sock")],
          &File.exists?/1
        )
    end
  end

  defp ctx(config) do
    test_pid = self()

    %{
      config: config,
      runner: ForemanAgent.Runner.Local,
      docker: Engine,
      log: fn stream, data -> send(test_pid, {:log, stream, data}) end
    }
  end

  defp create_payload(env_id, slug, base_url, overrides \\ %{}) do
    {:ok, cmd} =
      ForemanProtocol.Command.new(
        "env.create",
        Map.merge(
          %{
            "env_id" => env_id,
            "slug" => slug,
            "repo" => "acme/hello",
            "clone_url" => base_url <> "/hello.git",
            "branch" => "main",
            "files" => %{
              "secrets.env" => "export HELLO_SECRET='first value'\n",
              "gitconfig" => "[user]\n\tname = Foreman Test\n\temail = test@example.com\n"
            },
            "compose_env" => %{"SIDECAR_TOKEN" => "token-one"},
            "tailscale" => %{"enabled" => true}
          },
          overrides
        )
      )

    cmd.payload
  end

  defp containers(env_id) do
    {:ok, list} = Engine.list_containers(["foreman.env_id=#{env_id}"])
    Map.new(list, &{&1["Labels"]["com.docker.compose.service"], &1})
  end

  defp exec(container, args, user \\ "vscode") do
    System.cmd("docker", ["exec", "-u", user, container | args], stderr_to_stdout: true)
  end

  test "two copies of a repo run side by side, and the lifecycle works end to end", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)

    # -- create two copies -------------------------------------------------
    assert {:ok, r1} = Env.run("env.create", create_payload(@env1, "hello-1", base_url), ctx)
    assert {:ok, r2} = Env.run("env.create", create_payload(@env2, "hello-2", base_url), ctx)

    assert r1["remote_user"] == "vscode"
    assert r1["remote_workspace_folder"] == "/workspaces/hello"
    assert r1["services"] == ["app", "sidecar"]
    assert r1["compose_project"] == "hello-1"
    assert r2["compose_project"] == "hello-2"

    c1 = containers(@env1)
    c2 = containers(@env2)
    assert c1["app"]["State"] == "running"
    assert c1["sidecar"]["State"] == "running"
    assert c2["app"]["State"] == "running"

    # No published ports anywhere, and nothing restarts on its own.
    for c <- Map.values(c1) ++ Map.values(c2) do
      assert Enum.all?(c["Ports"] || [], &is_nil(&1["PublicPort"])),
             "#{inspect(c["Names"])} publishes a port"
    end

    {inspect, 0} =
      System.cmd("docker", [
        "inspect",
        c1["app"]["Id"],
        "--format",
        "{{json .HostConfig.RestartPolicy}}"
      ])

    assert inspect =~ ~s("Name":"no")

    # initializeCommand never ran on the box.
    refute File.exists?("/tmp/foreman-initialize-command-ran")

    # -- secrets, identity and the feature ----------------------------------
    app1 = c1["app"]["Id"]
    assert {"first value\n", 0} = exec(app1, ["bash", "-lc", "echo \"$HELLO_SECRET\""])
    assert {"test@example.com\n", 0} = exec(app1, ["git", "config", "user.email"])
    assert {version, 0} = exec(app1, ["tailscale", "version"])
    assert version =~ ~r/^1\.\d+/
    assert {_, 0} = exec(app1, ["test", "-c", "/dev/net/tun"], "root")
    assert {"hello-1\n", 0} = exec(app1, ["printenv", "TS_HOSTNAME"])

    # The secrets directory is read-only inside the container.
    assert {_, status} = exec(app1, ["touch", "/run/foreman/x"], "root")
    assert status != 0

    # The sidecar got the compose-interpolated value.
    {logs, 0} = System.cmd("docker", ["logs", c1["sidecar"]["Id"]], stderr_to_stdout: true)
    assert logs =~ "sidecar token=token-one"

    # The copies are isolated: separate volumes, separate secrets.
    assert {_, 0} = exec(c2["app"]["Id"], ["test", "-f", "/run/foreman/secrets.env"])

    # -- git status runs inside the container --------------------------------
    assert {:ok, %{"clean" => true, "branch" => "main"}} =
             Env.run("env.git_status", %{env_id: @env1, slug: "hello-1"}, ctx)

    exec(app1, ["bash", "-c", "echo change >> /workspaces/hello/README.md"])

    assert {:ok, %{"clean" => false, "changed_files" => 1}} =
             Env.run("env.git_status", %{env_id: @env1, slug: "hello-1"}, ctx)

    # -- new secrets reach new shells without a restart ----------------------
    assert {:ok, _} =
             Env.run(
               "env.secrets.write",
               %{
                 env_id: @env1,
                 files: %{
                   "secrets.env" => "export HELLO_SECRET='second value'\n",
                   "notices" => "pending\n"
                 }
               },
               ctx
             )

    assert {"second value\n", 0} = exec(app1, ["bash", "-lc", "echo \"$HELLO_SECRET\""])

    # -- restart affected recreates only the sidecar --------------------------
    poststarts = fn ->
      exec(containers(@env1)["app"]["Id"], ["wc", "-l", "/tmp/poststart.log"])
    end

    {before, 0} = poststarts.()
    old_sidecar = c1["sidecar"]["Id"]

    assert {:ok, %{"restarted" => ["sidecar", "app"]}} =
             Env.run(
               "env.restart",
               %{
                 env_id: @env1,
                 slug: "hello-1",
                 mode: "affected",
                 changed: ["SIDECAR_TOKEN"],
                 compose_env: %{"SIDECAR_TOKEN" => "token-two"}
               },
               ctx
             )

    c1 = containers(@env1)
    assert c1["sidecar"]["Id"] != old_sidecar
    assert c1["app"]["Id"] == app1
    {logs, 0} = System.cmd("docker", ["logs", c1["sidecar"]["Id"]], stderr_to_stdout: true)
    assert logs =~ "sidecar token=token-two"
    {after_restart, 0} = poststarts.()
    assert after_restart != before

    # -- stop and start ---------------------------------------------------------
    assert {:ok, _} = Env.run("env.stop", %{env_id: @env1, slug: "hello-1"}, ctx)
    assert containers(@env1) |> Map.values() |> Enum.all?(&(&1["State"] == "exited"))

    assert {:ok, _} =
             Env.run(
               "env.start",
               %{env_id: @env1, slug: "hello-1", compose_env: %{"SIDECAR_TOKEN" => "token-two"}},
               ctx
             )

    assert containers(@env1) |> Map.values() |> Enum.all?(&(&1["State"] == "running"))
    assert containers(@env1)["app"]["Id"] == app1

    # -- rebuild keeps the workspace ----------------------------------------------
    assert {:ok, _} = Env.run("env.rebuild", create_payload(@env1, "hello-1", base_url), ctx)
    new_app = containers(@env1)["app"]["Id"]
    assert new_app != app1
    assert {out, 0} = exec(new_app, ["cat", "/workspaces/hello/README.md"])
    assert out =~ "change"

    # -- logs ---------------------------------------------------------------------
    assert {:ok, _} =
             Env.run(
               "env.logs",
               %{env_id: @env1, slug: "hello-1", service: "sidecar", tail: 10},
               ctx
             )

    assert_received {:log, "stdout", _}

    # -- destroy --------------------------------------------------------------------
    for {env_id, slug} <- [{@env1, "hello-1"}, {@env2, "hello-2"}] do
      assert {:ok, _} = Env.run("env.destroy", %{env_id: env_id, slug: slug}, ctx)
      assert containers(env_id) == %{}
      refute File.exists?(Path.join(config.envs_root, env_id))
      refute File.exists?(Path.join(config.secrets_root, env_id))
    end

    {volumes, 0} =
      System.cmd("docker", [
        "volume",
        "ls",
        "-q",
        "--filter",
        "label=com.docker.compose.project=hello-1"
      ])

    assert volumes == ""
  end

  test "the policy sees through include, extends and interpolation", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)
    env_id = "44444444-4444-4444-8444-444444444444"

    payload =
      create_payload(env_id, "sneaky-1", base_url, %{
        "repo" => "acme/sneaky",
        "clone_url" => base_url <> "/sneaky.git",
        "tailscale" => %{"enabled" => false}
      })

    # HOME for the agent's children is the agent's own home, which is
    # inside its data directory here, as on a real box.
    ctx = put_in(ctx.config.data_dir, System.user_home!())

    assert {:error, message} = Env.run("env.create", payload, ctx)
    assert message =~ "protected"
    assert message =~ "helper"
    assert containers(env_id) == %{}
  end

  test "the policy refuses a feature that asks for privileged in its own metadata", %{
    config: config,
    base_url: base_url
  } do
    env_id = "55555555-5555-4555-8555-555555555555"

    payload =
      create_payload(env_id, "innocent-1", base_url, %{
        "repo" => "acme/innocent",
        "clone_url" => base_url <> "/innocent.git",
        "tailscale" => %{"enabled" => false}
      })

    assert {:error, message} = Env.run("env.create", payload, ctx(config))
    assert message =~ "./innocent"
    assert message =~ "privileged"
    assert containers(env_id) == %{}
  end

  test "the policy refuses a compose file rewritten from inside the environment", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)
    env_id = "33333333-3333-4333-8333-333333333333"
    payload = create_payload(env_id, "hello-3", base_url, %{"tailscale" => %{"enabled" => false}})

    assert {:ok, _} = Env.run("env.create", payload, ctx)

    on_exit(fn ->
      System.cmd("docker", ["compose", "-p", "hello-3", "down", "--volumes"],
        stderr_to_stdout: true
      )
    end)

    app = containers(env_id)["app"]["Id"]

    # Something in the environment adds a bind mount of the agent's state.
    evil = """
    services:
      app:
        volumes:
          - #{config.data_dir}:/stolen
    """

    {_, 0} =
      exec(app, [
        "bash",
        "-c",
        "cat > /workspaces/hello/.devcontainer/docker-compose.override.yml <<'EOF'\n#{evil}EOF"
      ])

    {_, 0} =
      exec(app, [
        "bash",
        "-c",
        ~s(cd /workspaces/hello/.devcontainer && sed -i 's/"docker-compose.yml"\\]/"docker-compose.yml", "docker-compose.override.yml"]/' devcontainer.json)
      ])

    assert {:ok, _} = Env.run("env.stop", %{env_id: env_id, slug: "hello-3"}, ctx)

    assert {:error, message} =
             Env.run("env.start", %{env_id: env_id, slug: "hello-3", compose_env: %{}}, ctx)

    assert message =~ "protected"

    assert {:ok, _} = Env.run("env.destroy", %{env_id: env_id, slug: "hello-3"}, ctx)
  end
end
