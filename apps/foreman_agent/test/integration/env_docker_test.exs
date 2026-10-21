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

  # CI's runners share one Docker daemon, so each run's compose projects,
  # volumes and env_id labels carry an id of their own (an .exs file is
  # compiled on every run).
  @run Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

  @env1 "#{@run}11-1111-4111-8111-111111111111"
  @env2 "#{@run}22-2222-4222-8222-222222222222"
  @slug1 "hello-#{@run}-1"
  @slug2 "hello-#{@run}-2"

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
      feature_dir: Path.expand("../../../../features/src/foreman", __DIR__)
    }

    File.mkdir_p!(config.envs_root)
    File.mkdir_p!(config.secrets_root)
    Config.put(config)

    on_exit(fn ->
      for slug <- [@slug1, @slug2] do
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

  # The repo's feature, at another version.
  defp feature_at(config, version) do
    dir = Path.join(Path.dirname(config.envs_root), "feature-#{version}")
    File.rm_rf!(dir)
    File.cp_r!(config.feature_dir, dir)
    json = Path.join(dir, "devcontainer-feature.json")

    File.write!(
      json,
      String.replace(File.read!(json), ~r/"version": "[^"]+"/, ~s("version": "#{version}"))
    )

    dir
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

  # Docker can report a container mid-transition for a moment after
  # compose returns, so poll briefly, and name the stragglers if any.
  defp assert_states(env_id, state, tries \\ 20) do
    states = Map.new(containers(env_id), fn {service, c} -> {service, c["State"]} end)

    cond do
      Enum.all?(states, fn {_, s} -> s == state end) ->
        :ok

      tries > 0 ->
        Process.sleep(500)
        assert_states(env_id, state, tries - 1)

      true ->
        flunk("expected every container #{state}, got #{inspect(states)}")
    end
  end

  defp exec(container, args, user \\ "vscode") do
    System.cmd("docker", ["exec", "-u", user, container | args], stderr_to_stdout: true)
  end

  # CAP_NET_ADMIN is bit 12 of the container's capability bounding set.
  defp net_admin?(container) do
    {status, 0} = exec(container, ["cat", "/proc/1/status"], "root")
    [hex] = Regex.run(~r/^CapBnd:\s+([0-9a-f]+)$/m, status, capture: :all_but_first)
    Bitwise.band(String.to_integer(hex, 16), Bitwise.bsl(1, 12)) != 0
  end

  # /proc/net/tcp lists addresses as little-endian hex, LISTEN is state 0A.
  defp listening?(container, {a, b, c, d}, port) do
    {tcp, 0} = exec(container, ["cat", "/proc/net/tcp"], "root")
    hex = fn n, width -> n |> Integer.to_string(16) |> String.pad_leading(width, "0") end
    want = Enum.map_join([d, c, b, a], &hex.(&1, 2)) <> ":" <> hex.(port, 4)

    tcp
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      match?([_, ^want, _, "0A" | _], String.split(line))
    end)
  end

  defp tailscale_log(container) do
    {log, _} = exec(container, ["cat", "/var/log/foreman-tailscale.log"], "root")
    log
  end

  defp eventually(fun, tries \\ 30) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(500) && eventually(fun, tries - 1)
    end
  end

  test "two copies of a repo run side by side, and the lifecycle works end to end", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)

    # -- create two copies -------------------------------------------------
    assert {:ok, r1} = Env.run("env.create", create_payload(@env1, @slug1, base_url), ctx)
    assert {:ok, r2} = Env.run("env.create", create_payload(@env2, @slug2, base_url), ctx)

    assert r1["remote_user"] == "vscode"
    assert r1["remote_workspace_folder"] == "/workspaces/hello"
    assert r1["services"] == ["app", "sidecar"]
    assert r1["compose_project"] == @slug1
    assert r2["compose_project"] == @slug2
    assert r1["feature_version"] == ForemanAgent.Config.feature_version(config)

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

    # Each copy's network is on its own Foreman bridge, which the box's
    # firewall matches on.
    for {env_id, slug} <- [{@env1, @slug1}, {@env2, @slug2}] do
      {bridge, 0} =
        System.cmd("docker", [
          "network",
          "inspect",
          "#{slug}_default",
          "--format",
          ~s({{index .Options "com.docker.network.bridge.name"}})
        ])

      assert String.trim(bridge) == Env.Overlay.bridge_name(env_id, "#{slug}_default")
    end

    # initializeCommand never ran on the box.
    refute File.exists?("/tmp/foreman-initialize-command-ran")

    # -- secrets, identity and the feature ----------------------------------
    app1 = c1["app"]["Id"]
    assert {"first value\n", 0} = exec(app1, ["bash", "-lc", "echo \"$HELLO_SECRET\""])
    assert {"test@example.com\n", 0} = exec(app1, ["git", "config", "user.email"])
    assert {version, 0} = exec(app1, ["tailscale", "version"])
    assert version =~ ~r/^1\.\d+/
    # Tailscale runs in userspace mode: no TUN device, no NET_ADMIN.
    assert {_, status} = exec(app1, ["test", "-e", "/dev/net/tun"], "root")
    assert status != 0
    refute net_admin?(app1)
    assert eventually(fn -> tailscale_log(app1) =~ "userspace networking" end)

    # Tailscale forwards tailnet connections to 127.0.0.1:<port>, so its
    # outbound proxy listens on 127.0.0.2, out of the tailnet's reach.
    assert eventually(fn -> listening?(app1, {127, 0, 0, 2}, 1055) end)
    refute listening?(app1, {127, 0, 0, 1}, 1055)
    assert exec(app1, ["printenv", "TS_HOSTNAME"]) == {@slug1 <> "\n", 0}

    # Tailscale SSH starts a clean login shell, without the container's
    # environment; the feature's profile hook brings it back.
    clean_login = ["env", "-i", "HOME=/home/vscode", "bash", "-lc"]
    assert exec(app1, clean_login ++ ["echo $FOREMAN_ENV"]) == {@slug1 <> "\n", 0}
    assert {"first value\n", 0} = exec(app1, clean_login ++ ["echo \"$HELLO_SECRET\""])

    # The secrets directory is read-only inside the container.
    assert {_, status} = exec(app1, ["touch", "/run/foreman/x"], "root")
    assert status != 0

    # The sidecar got the compose-interpolated value.
    {logs, 0} = System.cmd("docker", ["logs", c1["sidecar"]["Id"]], stderr_to_stdout: true)
    assert logs =~ "sidecar token=token-one"

    # The copies are isolated: separate volumes, separate secrets.
    assert {_, 0} = exec(c2["app"]["Id"], ["test", "-f", "/run/foreman/secrets.env"])

    # -- git status runs inside the container --------------------------------
    assert {:ok, %{"clean" => true, "branch" => "main", "head" => head, "base" => head}} =
             Env.run("env.git_status", %{env_id: @env1, slug: @slug1}, ctx)

    assert head =~ ~r/\A[0-9a-f]{40}\z/

    exec(app1, ["bash", "-c", "echo change >> /workspaces/hello/README.md"])

    assert {:ok, %{"clean" => false, "changed_files" => 1}} =
             Env.run("env.git_status", %{env_id: @env1, slug: @slug1}, ctx)

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
                 slug: @slug1,
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
    assert {:ok, _} = Env.run("env.stop", %{env_id: @env1, slug: @slug1}, ctx)
    assert_states(@env1, "exited")

    assert {:ok, started} =
             Env.run(
               "env.start",
               %{env_id: @env1, slug: @slug1, compose_env: %{"SIDECAR_TOKEN" => "token-two"}},
               ctx
             )

    assert_states(@env1, "running")
    assert containers(@env1)["app"]["Id"] == app1
    assert started["container_id"] == app1
    assert started["feature_version"] == r1["feature_version"]

    # -- a newer feature reaches the container only through a rebuild ----------------
    newer = ctx(%{config | feature_dir: feature_at(config, "9.9.9")})
    assert {:ok, _} = Env.run("env.stop", %{env_id: @env1, slug: @slug1}, ctx)

    assert {:ok, started} =
             Env.run(
               "env.start",
               %{env_id: @env1, slug: @slug1, compose_env: %{"SIDECAR_TOKEN" => "token-two"}},
               newer
             )

    assert started["container_id"] == app1
    assert started["feature_version"] == r1["feature_version"]

    # -- rebuild keeps the workspace ----------------------------------------------
    assert {:ok, rebuilt} =
             Env.run("env.rebuild", create_payload(@env1, @slug1, base_url), newer)

    new_app = containers(@env1)["app"]["Id"]
    assert new_app != app1
    assert rebuilt["feature_version"] == "9.9.9"
    assert {out, 0} = exec(new_app, ["cat", "/workspaces/hello/README.md"])
    assert out =~ "change"

    # -- pull and rebuild fast-forwards the clone, in the container -----------------
    # The container can't reach the test's git server, so origin becomes a
    # repo in the workspace, which it can.
    workspace = Path.join([config.envs_root, @env1, "workspace"])
    host_git = fn args -> {_, 0} = System.cmd("git", args, stderr_to_stdout: true) end

    host_git.([
      "clone",
      "-q",
      "--bare",
      base_url <> "/hello.git",
      Path.join(workspace, "upstream.git")
    ])

    container_git = ["git", "-c", "safe.directory=*", "-C", "/workspaces/hello"]

    {_, 0} =
      exec(new_app, container_git ++ ["remote", "set-url", "origin", "/workspaces/upstream.git"])

    work = Path.join(workspace, "upstream-work")
    host_git.(["clone", "-q", Path.join(workspace, "upstream.git"), work])
    File.write!(Path.join(work, "PULLED"), "yes\n")
    File.write!(Path.join(work, "local.env"), "theirs\n")
    host_git.(["-C", work, "add", "PULLED", "local.env"])

    host_git.([
      "-C",
      work,
      "-c",
      "user.name=T",
      "-c",
      "user.email=t@example.com",
      "commit",
      "-qm",
      "more"
    ])

    host_git.(["-C", work, "push", "-q", "origin", "main"])

    pull = Map.put(create_payload(@env1, @slug1, base_url), :pull, true)

    assert {:error, "1 changed file in the workspace; commit or stash it first",
            %{"pull_failed" => true}} = Env.run("env.rebuild", pull, ctx)

    assert containers(@env1)["app"]["Id"] == new_app, "a refused pull leaves it running"

    {_, 0} = exec(new_app, container_git ++ ["checkout", "README.md"])

    # A file the clone ignores, which the branch now tracks, isn't overwritten.
    clone = Path.join(workspace, "hello")
    File.write!(Path.join(clone, ".git/info/exclude"), "local.env\n", [:append])
    File.write!(Path.join(clone, "local.env"), "mine\n")

    assert {:error, message, %{"pull_failed" => true}} = Env.run("env.rebuild", pull, ctx)
    assert message =~ "local.env"
    assert File.read!(Path.join(clone, "local.env")) == "mine\n"

    File.rm!(Path.join(clone, "local.env"))
    assert {:ok, _} = Env.run("env.rebuild", pull, ctx)
    new_app = containers(@env1)["app"]["Id"]
    assert {"yes\n", 0} = exec(new_app, ["cat", "/workspaces/hello/PULLED"])

    # -- logs ---------------------------------------------------------------------
    assert {:ok, _} =
             Env.run(
               "env.logs",
               %{env_id: @env1, slug: @slug1, service: "sidecar", tail: 10},
               ctx
             )

    assert_received {:log, "stdout", _}

    # -- destroy --------------------------------------------------------------------
    for {env_id, slug} <- [{@env1, @slug1}, {@env2, @slug2}] do
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
        "label=com.docker.compose.project=#{@slug1}"
      ])

    assert volumes == ""
  end

  test "the policy sees through include, extends and interpolation", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)
    env_id = "#{@run}44-4444-4444-8444-444444444444"

    payload =
      create_payload(env_id, "sneaky-#{@run}-1", base_url, %{
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
    env_id = "#{@run}55-5555-4555-8555-555555555555"

    payload =
      create_payload(env_id, "innocent-#{@run}-1", base_url, %{
        "repo" => "acme/innocent",
        "clone_url" => base_url <> "/innocent.git",
        "tailscale" => %{"enabled" => false}
      })

    assert {:error, message} = Env.run("env.create", payload, ctx(config))
    assert message =~ "./innocent"
    assert message =~ "privileged"
    assert containers(env_id) == %{}
  end

  # The CLI reports a feature passed with --additional-features under the
  # ref it was given, which is how a refusal tells the user's own apart.
  test "the policy names a user's own feature it refuses", %{
    config: config,
    base_url: base_url
  } do
    env_id = "#{@run}66-6666-4666-8666-666666666666"
    ref = "ghcr.io/devcontainers/features/docker-in-docker:2"

    payload =
      create_payload(env_id, "hello-#{@run}-9", base_url, %{
        "tailscale" => %{"enabled" => false},
        "features" => %{ref => %{}}
      })

    assert {:error, message} = Env.run("env.create", payload, ctx(config))
    assert message =~ "your feature #{ref} (from your Foreman settings)"
    assert message =~ "privileged"
    assert containers(env_id) == %{}
  end

  test "the policy refuses a compose file rewritten from inside the environment", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)
    env_id = "#{@run}33-3333-4333-8333-333333333333"

    payload =
      create_payload(env_id, "hello-#{@run}-3", base_url, %{"tailscale" => %{"enabled" => false}})

    assert {:ok, _} = Env.run("env.create", payload, ctx)

    on_exit(fn ->
      System.cmd("docker", ["compose", "-p", "hello-#{@run}-3", "down", "--volumes"],
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

    assert {:ok, _} = Env.run("env.stop", %{env_id: env_id, slug: "hello-#{@run}-3"}, ctx)

    assert {:error, message} =
             Env.run(
               "env.start",
               %{env_id: env_id, slug: "hello-#{@run}-3", compose_env: %{}},
               ctx
             )

    assert message =~ "protected"

    assert {:ok, _} = Env.run("env.destroy", %{env_id: env_id, slug: "hello-#{@run}-3"}, ctx)
  end

  # Environments created before Foreman named their bridges: one running
  # on compose's own network, labelled with a config hash, so compose
  # recreates it once the project stops; and one whose network compose
  # would reuse as it is (an older compose made it without the label),
  # which is refused rather than taken down with its containers.
  test "an environment from before Foreman's bridges moves onto one when it starts", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)
    env_id = "#{@run}77-7777-4777-8777-777777777777"
    slug = "hello-#{@run}-4"
    payload = create_payload(env_id, slug, base_url, %{"tailscale" => %{"enabled" => false}})
    start = %{env_id: env_id, slug: slug, compose_env: %{"HELLO_TOKEN" => "token-one"}}

    assert {:ok, _} = Env.run("env.create", payload, ctx)

    on_exit(fn ->
      System.cmd("docker", ["compose", "-p", slug, "down", "--volumes"], stderr_to_stdout: true)
    end)

    bridge = fn ->
      {out, 0} =
        System.cmd("docker", [
          "network",
          "inspect",
          "#{slug}_default",
          "--format",
          ~s({{index .Options "com.docker.network.bridge.name"}})
        ])

      String.trim(out)
    end

    repo_file =
      Path.join([config.envs_root, env_id, "workspace/hello/.devcontainer/docker-compose.yml"])

    compose = fn args ->
      {_, 0} =
        System.cmd("docker", ["compose", "-p", slug | args],
          env: [{"HELLO_TOKEN", "token-one"}],
          stderr_to_stdout: true
        )
    end

    # Running on compose's network, without the overlay.
    compose.(["down"])
    compose.(["-f", repo_file, "up", "-d"])
    refute String.starts_with?(bridge.(), "fm-")

    assert {:ok, _} = Env.run("env.start", start, ctx)
    assert bridge.() == Env.Overlay.bridge_name(env_id, "#{slug}_default")

    # A network compose didn't label with a config hash.
    compose.(["down"])

    {_, 0} =
      System.cmd("docker", [
        "network",
        "create",
        "--label",
        "com.docker.compose.project=#{slug}",
        "--label",
        "com.docker.compose.network=default",
        "#{slug}_default"
      ])

    assert {:error, message} = Env.run("env.start", start, ctx)
    assert message =~ "#{slug}_default"
    assert containers(env_id) == %{}
  end

  # read-configuration looks for an existing container by the CLI's own
  # labels, and takes the merged config from that container instead of
  # resolving features. A repo that gives its service those labels, then
  # adds a privileged feature, must still be refused.
  test "a container label can't hide a feature from the policy", %{
    config: config,
    base_url: base_url
  } do
    ctx = ctx(config)
    env_id = "66666666-6666-4666-8666-666666666666"
    payload = create_payload(env_id, "hello-6", base_url, %{"tailscale" => %{"enabled" => false}})

    assert {:ok, _} = Env.run("env.create", payload, ctx)

    on_exit(fn ->
      System.cmd("docker", ["compose", "-p", "hello-6", "down", "--volumes"],
        stderr_to_stdout: true
      )
    end)

    clone = Env.paths(config, env_id, "acme/hello").clone
    devcontainer = Path.join(clone, ".devcontainer")

    # First the label, so the next container carries it.
    compose = File.read!(Path.join(devcontainer, "docker-compose.yml"))

    File.write!(
      Path.join(devcontainer, "docker-compose.yml"),
      String.replace(
        compose,
        "    command: sleep infinity\n",
        "    command: sleep infinity\n    labels:\n      devcontainer.local_folder: #{clone}\n",
        global: false
      )
    )

    first = Env.run("env.rebuild", payload, ctx)

    # Then a feature that asks for privileged.
    File.cp_r!(
      Path.expand("../fixtures/repos/innocent/.devcontainer/innocent", __DIR__),
      Path.join(devcontainer, "innocent")
    )

    json = File.read!(Path.join(devcontainer, "devcontainer.json"))

    File.write!(
      Path.join(devcontainer, "devcontainer.json"),
      String.replace(
        json,
        ~s("remoteUser": "vscode",),
        ~s("remoteUser": "vscode", "features": {"./innocent": {}},)
      )
    )

    second = Env.run("env.rebuild", payload, ctx)

    assert match?({:error, _}, first) or match?({:error, _}, second),
           "both rebuilds passed: #{inspect({first, second})}"

    for {_, container} <- containers(env_id) do
      {privileged, 0} =
        System.cmd("docker", ["inspect", "-f", "{{.HostConfig.Privileged}}", container["Id"]])

      assert String.trim(privileged) == "false", "a container came up privileged"
    end
  end
end
