defmodule ForemanAgent.EnvTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DevcontainerMock, DockerMock, Env, RunnerMock}

  @moduletag :tmp_dir

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @head "1111111111111111111111111111111111111111"
  @base "2222222222222222222222222222222222222222"

  @devcontainer """
  {
    // a comment
    "name": "storefront",
    "dockerComposeFile": ["docker-compose.yml"],
    "service": "app",
    "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
    "initializeCommand": "touch /tmp/pwned",
    "hostRequirements": {"cpus": 4, "memory": "8gb"},
  }
  """

  @joined ~s({"BackendState":"Running","Self":{"ID":"nTest1CNTRL","HostName":"storefront-2"}})

  @hook_dir "/usr/local/share/foreman/connect.d"
  @describe ~s({"label":"Orca","actions":[{"id":"desktop","label":"Pair a desktop","confirm":"Orca restarts."}]})
  @offer ~s({"value":"orca://pair?code=s3cretc0de","qr":false,"note":"Paste it into Orca."})

  setup :verify_on_exit!

  setup do
    stub(DockerMock, :list_containers, fn _labels -> {:ok, []} end)
    :ok
  end

  setup %{tmp_dir: tmp} do
    config = %Config{
      data_dir: Path.join(tmp, "data"),
      envs_root: Path.join(tmp, "envs"),
      secrets_root: Path.join(tmp, "run"),
      release_root: Path.join(tmp, "opt"),
      feature_dir: Path.expand("../../../../features/src/foreman", __DIR__),
      docker_socket: "/var/run/docker.sock"
    }

    File.mkdir_p!(config.envs_root)
    File.mkdir_p!(config.secrets_root)

    test_pid = self()
    log = fn stream, data -> send(test_pid, {:log, stream, data}) end

    ctx = %{
      config: config,
      runner: RunnerMock,
      docker: DockerMock,
      devcontainer: DevcontainerMock,
      log: log
    }

    %{config: config, ctx: ctx}
  end

  defp payload(overrides \\ %{}) do
    {:ok, cmd} =
      ForemanProtocol.Command.new(
        "env.create",
        Map.merge(
          %{
            "env_id" => @env_id,
            "slug" => "storefront-2",
            "repo" => "acme/storefront",
            "clone_url" => "https://github.com/acme/storefront.git",
            "branch" => "main",
            "files" => %{"secrets.env" => "export A='1'\n", "github-token" => "ghu_secret"},
            "compose_env" => %{"NEON_API_KEY" => "neon_secret"},
            "tailscale" => %{"enabled" => true}
          },
          overrides
        )
      )

    cmd.payload
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # A runner that behaves like git and docker compose, and a devcontainer
  # that comes up.
  defp stub_tools(opts \\ []) do
    test_pid = self()
    compose = Keyword.get(opts, :compose, %{"services" => %{"app" => %{}, "db" => %{}}})
    devcontainer = Keyword.get(opts, :devcontainer, @devcontainer)
    outcome = Keyword.get(opts, :outcome, :success)
    docker_info = Keyword.get(opts, :docker_info, {:ok, %{"DefaultRuntime" => "runc"}})
    tailscale = Keyword.get(opts, :tailscale, fn -> {0, @joined} end)

    containers = fake_containers()
    stub_engine(docker_info, containers, opts)

    stub(DevcontainerMock, :up, fn params, ctx ->
      up_opts = [env: params.env, timeout: params.timeout]
      send(test_pid, {:run, "devcontainer", params, up_opts})
      Keyword.get(opts, :before_up, fn _ -> :ok end).(up_opts)
      container = fake_up(containers, params)
      ctx.log.("info", "Building image\n")
      up_result(outcome, container)
    end)

    stub(RunnerMock, :run, fn command, args, run_opts ->
      send(test_pid, {:run, command, args, run_opts})

      case {command, args} do
        {"git", args} ->
          fake_git(args, devcontainer, opts)

        {"docker", ["compose" | _] = args} ->
          fake_docker(args, compose, containers, opts)

        {"docker", ["pull" | _]} ->
          {:ok, %{status: 0, output: ""}}

        {"docker", ["exec", "-u", "0", _container, "tailscale" | _]} ->
          {status, output} = tailscale.()
          {:ok, %{status: status, output: output}}

        {"docker", ["exec" | rest]} ->
          container_exec(rest, opts, run_opts)

        other ->
          flunk("unexpected command: #{inspect(other)}")
      end
    end)
  end

  # git, run on the clone after a prebuild's is taken over: `:git_refresh`
  # answers it.
  defp fake_git(args, devcontainer, opts) do
    if "clone" in args,
      do: fake_clone(args, devcontainer),
      else:
        Keyword.get(opts, :git_refresh, fn _args -> {:ok, %{status: 0, output: ""}} end).(args)
  end

  defp fake_clone(args, devcontainer) do
    dest = List.last(args)
    File.mkdir_p!(Path.join(dest, ".git/info"))
    File.mkdir_p!(Path.join(dest, ".devcontainer"))
    File.write!(Path.join(dest, ".devcontainer/devcontainer.json"), devcontainer)
    File.write!(Path.join(dest, ".devcontainer/docker-compose.yml"), "services: {}\n")
    {:ok, %{status: 0, output: "Cloning into '#{dest}'...\n"}}
  end

  # The environment's devcontainer, as Docker would have it: the CLI
  # reuses one that exists unless it's told to remove it, and keeps one it
  # made even when setting it up fails.
  defp fake_containers do
    with nil <- Process.get(:fake_containers) do
      {:ok, pid} = Agent.start_link(fn -> nil end)
      Process.put(:fake_containers, pid)
      pid
    end
  end

  defp fake_up(containers, params) do
    overlay = List.last(params.config["dockerComposeFile"])

    label =
      case Regex.run(~r/"foreman.feature_version": "([^"]+)"/, File.read!(overlay)) do
        [_, version] -> version
        nil -> nil
      end

    remove? = params.remove_existing

    Agent.get_and_update(containers, fn
      %{} = c when not remove? ->
        {c.id, %{c | state: "running"}}

      previous ->
        id = if previous, do: "abc123-#{System.unique_integer([:positive])}", else: "abc123"
        {id, %{id: id, state: "running", label: label}}
    end)
  end

  defp fake_container(c) do
    labels = %{"com.docker.compose.service" => "app", "foreman.env_id" => @env_id}
    labels = if c.label, do: Map.put(labels, "foreman.feature_version", c.label), else: labels
    %{"Id" => c.id, "State" => c.state, "Labels" => labels}
  end

  # What happens to the container outside the agent.
  defp update_container(fun), do: Agent.update(fake_containers(), fun)

  defp up_result(:success, container) do
    {:ok,
     %{
       container_id: container,
       remote_user: "vscode",
       remote_workspace_folder: "/workspaces/storefront",
       compose_project: "storefront-2"
     }}
  end

  defp up_result(:error, _container), do: {:error, "build failed"}
  defp up_result({:error, message}, _container), do: {:error, message}

  # The feature check lists the environment's containers by its label,
  # the bridge check the project's; :containers stands in for the latter.
  defp stub_engine(docker_info, containers, opts) do
    stub(DockerMock, :info, fn -> docker_info end)

    networks = Keyword.get(opts, :networks, fn _filters -> [] end)
    stub(DockerMock, :list_networks, fn filters -> {:ok, networks.(filters)} end)

    stub(DockerMock, :list_containers, fn
      ["foreman.env_id=" <> @env_id] ->
        {:ok, containers |> Agent.get(& &1) |> List.wrap() |> Enum.map(&fake_container/1)}

      ["com.docker.compose.project=" <> _] ->
        {:ok, Keyword.get(opts, :containers, [])}
    end)
  end

  # The docker CLI, short of exec.
  defp fake_docker(["compose", "-p", _, "stop"] = args, compose, containers, opts) do
    case Keyword.get(opts, :compose_stop, :ok) do
      :ok -> fake_compose(tl(args), compose, containers)
      {:error, output} -> {:ok, %{status: 1, output: output}}
    end
  end

  defp fake_docker(["compose" | rest], compose, containers, _opts),
    do: fake_compose(rest, compose, containers)

  defp fake_compose(args, compose, containers) do
    if "stop" in args, do: Agent.update(containers, &(&1 && %{&1 | state: "exited"}))
    if "down" in args, do: Agent.update(containers, fn _ -> nil end)

    if "config" in args do
      out = args |> Enum.drop_while(&(&1 != "-o")) |> Enum.at(1)
      File.write!(out, JSON.encode!(compose))
    end

    {:ok, %{status: 0, output: ""}}
  end

  # Connect hooks, or git.
  defp container_exec(["-u", _, "-w", _, _, "sh", "-c", _], opts, _run_opts),
    do: connect_hooks(Keyword.get(opts, :connect), ["list"])

  defp container_exec(
         ["-u", _, "-w", _, _, "sh", "-c", _, "sh", _secs, @hook_dir <> "/" <> hook | args],
         opts,
         _run_opts
       ),
       do: connect_hooks(Keyword.get(opts, :connect), [hook | args])

  defp container_exec(rest, opts, run_opts),
    do: container_git(Keyword.get(opts, :git), rest, run_opts)

  # `answer` takes ["list"] (the hooks the container has), or a hook's name
  # and arguments, and returns {status, output}. Without one, there are no
  # hooks.
  defp connect_hooks(nil, ["list"]), do: {:ok, %{status: 0, output: ""}}
  defp connect_hooks(nil, args), do: flunk("unexpected connect hook run: #{inspect(args)}")

  defp connect_hooks(answer, args) do
    {status, output} = answer.(args)
    {:ok, %{status: status, output: output}}
  end

  # `answer` takes git's arguments (after the -c options) and returns
  # {status, output}.
  defp container_git(nil, rest, _run_opts), do: flunk("unexpected docker exec: #{inspect(rest)}")

  defp container_git(answer, rest, run_opts) do
    {status, output} = answer.(rest |> Enum.drop_while(&(&1 != "core.fsmonitor=false")) |> tl())
    if status == 0, do: run_opts[:on_output].(output)
    {:ok, %{status: status, output: output}}
  end

  defp runs do
    receive_all([])
  end

  # The last time the devcontainer was brought up; asking Tailscale for the node comes after.
  defp last_devcontainer do
    runs() |> Enum.filter(&match?({"devcontainer", _, _}, &1)) |> List.last()
  end

  # Everything the operation logged so far, in order.
  defp logged do
    receive do
      {:log, "info", text} -> [text | logged()]
    after
      0 -> []
    end
  end

  defp receive_all(acc) do
    receive do
      {:run, command, args, opts} -> receive_all([{command, args, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "create" do
    test "writes secrets, clones, prepares and runs devcontainer up", %{ctx: ctx, config: config} do
      stub_tools()

      assert {:ok, result} = Env.run("env.create", payload(), ctx)

      assert result["container_id"] == "abc123"
      assert result["remote_user"] == "vscode"
      assert result["remote_workspace_folder"] == "/workspaces/storefront"
      assert result["services"] == ["app", "db"]
      assert result["host_requirements"] == %{"cpus" => 4, "memory" => "8gb"}

      secrets = Path.join(config.secrets_root, @env_id)
      assert File.read!(Path.join(secrets, "github-token")) == "ghu_secret"
      assert mode(secrets) == 0o700
      assert mode(Path.join(secrets, "secrets.env")) == 0o600

      clone = Path.join([config.envs_root, @env_id, "workspace", "storefront"])
      meta = Path.join([config.envs_root, @env_id, "meta"])

      # Compose runs once, for the services the overlay covers.
      [git, services, up, _tailscale, _connect] = runs()

      {"git", git_args, git_opts} = git

      assert Enum.take(git_args, -5) == [
               "--branch",
               "main",
               "--",
               "https://github.com/acme/storefront.git",
               clone
             ]

      refute Enum.any?(git_args, &(&1 =~ "ghu_secret"))
      assert Enum.any?(git_args, &String.starts_with?(&1, "credential.helper=" <> meta))
      refute Map.has_key?(git_opts[:env], "NEON_API_KEY")

      {"devcontainer", up_params, up_opts} = up
      assert up_params.workspace == clone
      assert up_params.config_path == Path.join(clone, ".devcontainer/devcontainer.json")
      assert up_params.id_labels == ["foreman.env_id=#{@env_id}"]
      assert up_params.additional_features == %{"./.foreman/feature" => %{"tailscale" => true}}
      assert up_params.state_dir == Path.join(meta, "devcontainer")
      assert up_params.remove_existing == false
      assert up_params.dotfiles == nil

      refute inspect(Map.delete(up_params, :env)) =~ "neon_secret"
      assert up_opts[:env]["NEON_API_KEY"] == "neon_secret"
      assert up_opts[:env]["COMPOSE_PROJECT_NAME"] == "storefront-2"

      # A service the repo's compose files no longer have goes on the next
      # up. Only there: a compose run with fewer files would count the
      # missing services as orphans.
      assert up_opts[:env]["COMPOSE_REMOVE_ORPHANS"] == "true"

      {_, _, services_opts} = services
      refute Map.has_key?(services_opts[:env], "COMPOSE_REMOVE_ORPHANS")

      # The environment's VM is the boundary, so the initialize command
      # runs in the VM, outside the containers.
      override = up_params.config
      assert override["initializeCommand"] == "touch /tmp/pwned"
      assert override["workspaceFolder"] == "/workspaces/${localWorkspaceFolderBasename}"
      refute File.exists?(Path.join(meta, "devcontainer.json"))

      assert override["dockerComposeFile"] == [
               Path.join(clone, ".devcontainer/docker-compose.yml"),
               Path.join(meta, "overlay.yml")
             ]

      overlay = File.read!(Path.join(meta, "overlay.yml"))
      refute overlay =~ "/mnt/foreman-recovery"
      assert overlay =~ "ports: !reset []"
      assert overlay =~ ~s(source: "#{secrets}")

      assert File.exists?(
               Path.join(clone, ".devcontainer/.foreman/feature/devcontainer-feature.json")
             )

      assert File.read!(Path.join(clone, ".git/info/exclude")) =~ "/.devcontainer/.foreman/"

      assert_received {:log, "info", "Starting the devcontainer\n"}
      assert_received {:log, "info", "Building image\n"}
    end

    test "reports the node the environment joined the tailnet as", %{ctx: ctx} do
      stub_tools()

      assert {:ok, result} = Env.run("env.create", payload(), ctx)
      assert result["tailscale_node_id"] == "nTest1CNTRL"

      # Asked inside the devcontainer, after it's up.
      {"docker", args, opts} =
        Enum.find(runs(), &match?({"docker", ["exec", "-u", "0" | _], _}, &1))

      assert args == [
               "exec",
               "-u",
               "0",
               "abc123",
               "tailscale",
               "--socket=/var/run/tailscale/tailscaled.sock",
               "status",
               "--json",
               "--peers=false"
             ]

      assert opts[:timeout] <= :timer.seconds(15)
    end

    test "waits for the node to join", %{ctx: ctx, config: config} do
      calls = :counters.new(1, [])

      stub_tools(
        tailscale: fn ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) < 3,
            do: {0, ~s({"BackendState":"NeedsLogin","Self":{"ID":""}})},
            else: {0, @joined}
        end
      )

      ctx = %{ctx | config: %{config | tailscale_join_wait: 5_000}}
      assert {:ok, result} = Env.run("env.create", payload(), ctx)
      assert result["tailscale_node_id"] == "nTest1CNTRL"
      assert :counters.get(calls, 1) == 3
    end

    test "still succeeds when the node hasn't joined in time", %{ctx: ctx, config: config} do
      stub_tools(tailscale: fn -> {1, "failed to connect to local tailscaled"} end)

      ctx = %{ctx | config: %{config | tailscale_join_wait: 0}}
      assert {:ok, result} = Env.run("env.create", payload(), ctx)
      refute Map.has_key?(result, "tailscale_node_id")
      assert Enum.any?(logged(), &(&1 =~ "hasn't joined the tailnet"))
    end

    test "ignores a node ID that isn't one", %{ctx: ctx, config: config} do
      stub_tools(
        tailscale: fn -> {0, ~s({"BackendState":"Running","Self":{"ID":"n1/../../x"}})} end
      )

      ctx = %{ctx | config: %{config | tailscale_join_wait: 0}}
      assert {:ok, result} = Env.run("env.create", payload(), ctx)
      refute Map.has_key?(result, "tailscale_node_id")
    end

    test "doesn't look for a node without Tailscale", %{ctx: ctx} do
      stub_tools(tailscale: fn -> flunk("asked tailscale") end)

      assert {:ok, result} =
               Env.run("env.create", payload(%{"tailscale" => %{"enabled" => false}}), ctx)

      refute Map.has_key?(result, "tailscale_node_id")
    end

    test "doesn't leave a feature lockfile behind unless the repo keeps one", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      {"devcontainer", params, _} = last_devcontainer()
      refute params.lockfile

      clone = Path.join([ctx.config.envs_root, @env_id, "workspace", "storefront"])
      File.write!(Path.join(clone, ".devcontainer/devcontainer-lock.json"), "{}")
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      {"devcontainer", params, _} = last_devcontainer()
      assert params.lockfile
    end

    test "passes dotfiles on to the devcontainer", %{ctx: ctx} do
      stub_tools()

      dotfiles = %{
        "repository" => "https://github.com/mona/dotfiles.git",
        "install_command" => "./install.sh"
      }

      assert {:ok, _} = Env.run("env.create", payload(%{"dotfiles" => dotfiles}), ctx)

      {"devcontainer", params, _} = last_devcontainer()
      assert params.dotfiles.repository == "https://github.com/mona/dotfiles.git"
      assert params.dotfiles.install_command == "./install.sh"
      assert params.dotfiles[:target_path] == nil
    end

    test "adds the user's features alongside Foreman's", %{ctx: ctx} do
      stub_tools()
      orca = %{"ghcr.io/ntodd/devcontainer-features/orca:1" => %{"server" => true}}

      assert {:ok, _} = Env.run("env.create", payload(%{"features" => orca}), ctx)

      [_git, _services, {"devcontainer", up_args, _} | _] = runs()

      expected =
        Map.put(orca, "./.foreman/feature", %{"tailscale" => true})

      assert up_args.additional_features == expected
    end

    test "skips a user feature the repo already declares, whatever its version or case", %{
      ctx: ctx
    } do
      stub_tools(
        devcontainer: """
        {
          "dockerComposeFile": ["docker-compose.yml"],
          "service": "app",
          "features": {"GHCR.IO/devcontainers/features/Node:1": {"version": "20"}}
        }
        """
      )

      features = %{
        "ghcr.io/devcontainers/features/node:2" => %{"version" => "22"},
        "ghcr.io/ntodd/devcontainer-features/orca:1" => %{}
      }

      assert {:ok, _} = Env.run("env.create", payload(%{"features" => features}), ctx)

      {"devcontainer", up_args, _} = last_devcontainer()

      assert up_args.additional_features == %{
               "ghcr.io/ntodd/devcontainer-features/orca:1" => %{},
               "./.foreman/feature" => %{"tailscale" => true}
             }

      assert_received {:log, "info",
                       "Skipping your feature ghcr.io/devcontainers/features/node:2" <> rest}

      assert rest =~ "already declares"
    end

    test "refuses a user feature that would stand in for Foreman's", %{ctx: ctx} do
      stub_tools()
      features = %{"ghcr.io/mona/features/foreman:1" => %{}}

      assert {:error, message} = Env.run("env.create", payload(%{"features" => features}), ctx)
      assert message =~ "ghcr.io/mona/features/foreman:1"
      assert message =~ "your feature"
      refute Enum.any?(runs(), &match?({"devcontainer", _, _}, &1))
    end

    test "refuses clone hosts that aren't allowed, before running anything", %{ctx: ctx} do
      stub_tools()

      assert {:error, message} =
               Env.run("env.create", payload(%{"clone_url" => "https://evil.example/x.git"}), ctx)

      assert message =~ "evil.example"
      assert runs() == []
    end

    test "refuses plain http unless the host is marked insecure", %{ctx: ctx} do
      stub_tools()
      p = payload(%{"clone_url" => "http://git.local:8080/storefront.git"})

      ctx = put_in(ctx.config.allowed_git_hosts, ["git.local"])
      assert {:error, message} = Env.run("env.create", p, ctx)
      assert message =~ "https"

      ctx = put_in(ctx.config.insecure_git_hosts, ["git.local"])
      assert {:ok, _} = Env.run("env.create", p, ctx)
    end

    test "requires a compose-based devcontainer", %{ctx: ctx} do
      stub_tools(devcontainer: ~s({"image": "mcr.microsoft.com/devcontainers/base"}))
      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "compose"
    end

    test "refuses compose files outside the clone", %{ctx: ctx} do
      stub_tools(
        devcontainer: ~s({"dockerComposeFile": "../../../../etc/compose.yml", "service": "app"})
      )

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "outside the repository"
    end

    test "reports a devcontainer that didn't come up", %{ctx: ctx} do
      stub_tools(outcome: :error)

      assert Env.run("env.create", payload(), ctx) ==
               {:error, "devcontainer up failed: build failed"}
    end

    test "reports one that ran out of time in its own words", %{ctx: ctx} do
      timed_out = "devcontainer up timed out after 165 minutes and was stopped"
      stub_tools(outcome: {:error, timed_out})

      assert Env.run("env.create", payload(), ctx) == {:error, timed_out}
    end

    test "cleans up a tool's own spinner, cursor movement and links", %{ctx: ctx} do
      output =
        Enum.join([
          "Cloning into '/w'...\n",
          "Receiving objects:  50% (1/2)\rReceiving objects: 100% (2/2), done.\n",
          "⠋ Resolving deltas\n",
          "\e[1D\n",
          "\e[0K\n",
          "⠙ Resolving deltas\n",
          "remote: Repository not found.\r\r\n",
          "remote: Check the URL.\e[1G\n",
          "fatal: \e]8;;https://example.com/help\e\\authentication failed\e]8;;\e\\\n"
        ])

      stub(RunnerMock, :run, fn "git", _args, run_opts ->
        run_opts[:on_output].(output)
        {:ok, %{status: 128, output: output}}
      end)

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "fatal: authentication failed"
      assert length(String.split(message, "Resolving deltas")) == 2

      logged = logged()
      assert Enum.count(logged, &(&1 =~ "Resolving deltas")) == 1
      assert "fatal: authentication failed\n" in logged
      assert "Receiving objects: 100% (2/2), done.\n" in logged
      assert "remote: Repository not found.\n" in logged
      assert "remote: Check the URL.\n" in logged
      refute Enum.any?(logged, &(&1 =~ "50%"))
      refute "\n" in logged
    end

    test "a device driver failure without a GPU request is reported as it is", %{ctx: ctx} do
      stub_tools(
        outcome: {:error, ~s(could not select device driver "" with capabilities: [[x]])}
      )

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "could not select device driver"
      refute message =~ "NVIDIA"
    end

    test "is idempotent: a retried create reuses the clone", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()

      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      refute Enum.any?(runs(), &match?({"git", _, _}, &1))
    end

    # Cancelling an operation kills its process, so cleanup in the
    # process itself never runs.
    test "registry credentials don't outlive a build that's killed", %{ctx: ctx} do
      test_pid = self()

      stub_tools(
        before_up: fn run_opts ->
          send(test_pid, {:up, run_opts[:env]["DOCKER_CONFIG"]})
          Process.sleep(:infinity)
        end
      )

      auth = [%{"host" => "ghcr.io", "username" => "machine", "token" => "ghp_registry"}]

      pid =
        spawn(fn ->
          receive do
            :go -> Env.run("env.create", payload(%{"registry_auth" => auth}), ctx)
          end
        end)

      allow(RunnerMock, test_pid, pid)
      allow(DockerMock, test_pid, pid)
      allow(DevcontainerMock, test_pid, pid)
      send(pid, :go)

      assert_receive {:up, docker_config}, 5_000
      assert File.exists?(Path.join(docker_config, "config.json"))

      Process.exit(pid, :kill)
      assert eventually(fn -> not File.exists?(docker_config) end)
    end

    test "registry credentials left by an agent that died are swept at start", %{config: config} do
      leftover = Path.join([Env.paths(config, @env_id).meta, "docker-abc", "config.json"])
      File.mkdir_p!(Path.dirname(leftover))
      File.write!(leftover, ~s({"auths":{}}))
      on_tmpfs = Path.join([config.secrets_root, ".docker-def", "config.json"])
      File.mkdir_p!(Path.dirname(on_tmpfs))
      File.write!(on_tmpfs, ~s({"auths":{}}))
      spec = Path.join(Env.paths(config, @env_id).meta, "spec.term")
      File.write!(spec, "keep")

      :ok = Env.sweep_docker_configs(config)

      refute File.exists?(Path.dirname(leftover))
      refute File.exists?(Path.dirname(on_tmpfs))
      assert File.exists?(spec)
    end

    test "writes registry credentials to a throwaway docker config, never argv", %{ctx: ctx} do
      stub_tools()
      auth = [%{"host" => "ghcr.io", "username" => "machine", "token" => "ghp_registry"}]

      assert {:ok, _} = Env.run("env.create", payload(%{"registry_auth" => auth}), ctx)

      [{"devcontainer", args, opts}] = Enum.filter(runs(), &match?({"devcontainer", _, _}, &1))

      refute inspect(args) =~ "ghp_registry"
      docker_config = opts[:env]["DOCKER_CONFIG"]
      assert is_binary(docker_config)
      refute File.exists?(docker_config)
    end

    # The environment's disk can become a prebuild that other people's
    # environments start from, and a deleted file's blocks stay on it.
    test "registry credentials never touch the environment's disk", %{ctx: ctx, config: config} do
      stub_tools()
      auth = [%{"host" => "ghcr.io", "username" => "machine", "token" => "ghp_registry"}]

      assert {:ok, _} = Env.run("env.create", payload(%{"registry_auth" => auth}), ctx)

      [{"devcontainer", _, opts}] = Enum.filter(runs(), &match?({"devcontainer", _, _}, &1))
      assert String.starts_with?(opts[:env]["DOCKER_CONFIG"], config.secrets_root <> "/")
      refute String.starts_with?(opts[:env]["DOCKER_CONFIG"], config.envs_root)
    end
  end

  describe "prebuilds" do
    @prebuild_id "0b0e5c55-7d0b-4c8e-9e6f-3a2b1c0d9e8f"

    # What building a prebuild leaves on the disk: the clone, the saved
    # spec, and whatever the prebuild's own code left in the clone's git
    # directory.
    defp prebuilt_disk(config) do
      from = Env.paths(config, @prebuild_id, "acme/storefront")
      File.mkdir_p!(Path.join(from.clone, ".git/hooks"))
      File.mkdir_p!(Path.join(from.clone, ".devcontainer"))
      File.write!(Path.join(from.clone, ".devcontainer/devcontainer.json"), @devcontainer)
      File.write!(Path.join(from.clone, ".devcontainer/docker-compose.yml"), "services: {}\n")
      File.write!(Path.join(from.clone, "node_modules.txt"), "built by the prebuild")

      File.write!(Path.join(from.clone, ".git/config"), """
      [core]
      \tfsmonitor = /tmp/evil
      [credential]
      \thelper = /tmp/evil
      """)

      File.write!(Path.join(from.clone, ".git/hooks/post-checkout"), "#!/bin/sh\nevil\n")
      # Git objects of its own choosing, standing in for the branch's.
      File.mkdir_p!(Path.join(from.clone, ".git/refs/replace"))

      File.write!(
        Path.join(from.clone, ".git/refs/replace/" <> String.duplicate("a", 40)),
        String.duplicate("b", 40)
      )

      File.mkdir_p!(Path.join(from.clone, ".git/objects/info"))
      File.write!(Path.join(from.clone, ".git/objects/info/alternates"), "/tmp/evil/objects\n")
      File.mkdir_p!(from.meta)

      File.write!(
        Path.join(from.meta, "spec.term"),
        :erlang.term_to_binary(%{slug: "prebuild-0b0e5c55", env_id: @prebuild_id})
      )

      from
    end

    defp record_git(test) do
      fn args ->
        send(test, {:git_run, args})
        {:ok, %{status: 0, output: ""}}
      end
    end

    test "an environment takes over a prebuild's clone, brought up to date with its own token",
         %{ctx: ctx, config: config} do
      stub_tools(git_refresh: record_git(self()))
      from = prebuilt_disk(config)

      assert {:ok, _} = Env.run("env.create", payload(%{"prebuild_id" => @prebuild_id}), ctx)

      runs = runs()
      refute Enum.any?(runs, fn {cmd, args, _} -> cmd == "git" and "clone" in args end)
      refute File.exists?(from.env_dir)
      assert_received {:log, "info", "Starting from the prebuild\n"}

      to = Env.paths(config, @env_id, "acme/storefront")
      # What the prebuild's code left can't run as the agent, or in git later.
      git_config = File.read!(Path.join(to.clone, ".git/config"))
      refute git_config =~ "evil"
      assert git_config =~ "url = https://github.com/acme/storefront.git"
      assert File.ls!(Path.join(to.clone, ".git/hooks")) == []
      # A git directory of its own, fetched from the remote: nothing the
      # prebuild's code put in the old one is used.
      refute File.exists?(Path.join(to.clone, ".git/refs/replace"))
      refute File.exists?(Path.join(to.clone, ".git/objects/info/alternates"))
      assert_received {:git_run, init}
      assert "init" in init

      helper = Path.join(to.meta, "git-credential")
      assert File.read!(helper) =~ Path.join(to.secrets, "github-token")
      assert_received {:git_run, fetch}
      assert ("credential.helper=" <> helper) in fetch
      assert "fetch" in fetch
      assert_received {:git_run, checkout}

      assert ["checkout", "-f", "-B", "main", "refs/remotes/origin/main"] ==
               Enum.take(checkout, -5)

      # What the prebuild's hooks made stays.
      assert File.exists?(Path.join(to.clone, "node_modules.txt"))

      # The prebuild's own containers and volumes go.
      assert Enum.any?(runs, fn
               {"docker", ["compose", "-p", "prebuild-0b0e5c55", "down" | rest], _} ->
                 "--volumes" in rest

               _ ->
                 false
             end)
    end

    test "a prebuild's clone that can't be brought up to date is cloned afresh",
         %{ctx: ctx, config: config} do
      stub_tools(
        git_refresh: fn
          ["-c" | _] = args ->
            if "fetch" in args,
              do: {:ok, %{status: 128, output: "fatal: couldn't find remote ref main"}},
              else: {:ok, %{status: 0, output: ""}}
        end
      )

      prebuilt_disk(config)
      assert {:ok, _} = Env.run("env.create", payload(%{"prebuild_id" => @prebuild_id}), ctx)
      assert Enum.any?(runs(), fn {cmd, args, _} -> cmd == "git" and "clone" in args end)

      refute File.exists?(
               Path.join(Env.paths(config, @env_id, "acme/storefront").clone, "node_modules.txt")
             )
    end

    test "a create from a prebuild that fails never comes back as the prebuild",
         %{ctx: ctx, config: config} do
      stub_tools(outcome: :error, git_refresh: record_git(self()))
      prebuilt_disk(config)

      assert {:error, _} = Env.run("env.create", payload(%{"prebuild_id" => @prebuild_id}), ctx)
      refute File.exists?(Path.join(Env.paths(config, @env_id).meta, "spec.term"))
    end

    test "without the prebuild's files, it clones as usual", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.create", payload(%{"prebuild_id" => @prebuild_id}), ctx)
      assert Enum.any?(runs(), fn {cmd, args, _} -> cmd == "git" and "clone" in args end)
    end

    test "building one keeps its Dockerfiles' base images by tag", %{ctx: ctx, config: config} do
      clone = Env.paths(config, @env_id, "acme/storefront").clone
      context = Path.join(clone, ".devcontainer")

      compose = %{
        "services" => %{
          "app" => %{"build" => %{"context" => context, "dockerfile" => "Dockerfile"}},
          "db" => %{"image" => "postgres:17"},
          "worker" => %{
            "build" => %{"context" => context, "dockerfile_inline" => "FROM alpine:3.22\n"}
          },
          # A Dockerfile outside the clone isn't read.
          "outside" => %{"build" => %{"context" => config.data_dir, "dockerfile" => "Dockerfile"}}
        }
      }

      File.mkdir_p!(config.data_dir)
      File.write!(Path.join(config.data_dir, "Dockerfile"), "FROM outside:1\n")

      stub_tools(
        compose: compose,
        before_up: fn _ ->
          File.write!(Path.join(context, "Dockerfile"), """
          ARG VARIANT=3
          FROM --platform=linux/amd64 mcr.microsoft.com/devcontainers/base:debian AS base
          FROM base AS dev
          FROM node:${VARIANT}
          RUN python3 - <<EOF
          from os import path
          EOF
          FROM scratch
          FROM python:3.12-slim@sha256:#{String.duplicate("a", 64)}
          """)
        end
      )

      assert {:ok, _} = Env.run("env.create", payload(%{"prebuild" => true}), ctx)

      pulled = for {"docker", ["pull" | args], _} <- runs(), do: List.last(args)

      assert Enum.sort(pulled) == [
               "alpine:3.22",
               "mcr.microsoft.com/devcontainers/base:debian",
               "python:3.12-slim@sha256:#{String.duplicate("a", 64)}"
             ]
    end

    test "an environment's own create pulls nothing more", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      refute Enum.any?(runs(), &match?({"docker", ["pull" | _], _}, &1))
    end
  end

  describe "recovering a failed first create" do
    test "retry and rebuild keep each previous checkout and expose them in the new container", %{
      ctx: ctx,
      config: config
    } do
      paths = Env.paths(config, @env_id, "acme/storefront")
      stub_tools(outcome: :error)
      assert {:error, _} = Env.run("env.create", payload(), ctx)

      tracked = ".devcontainer/docker-compose.yml"
      File.write!(Path.join(paths.clone, tracked), "edited compose file")
      File.write!(Path.join(paths.clone, "notes"), "untracked notes")
      File.write!(Path.join(paths.clone, ".git/HEAD"), "ref: refs/heads/local-work")

      assert {:error, _} = Env.run("env.create", payload(), ctx)
      refute File.exists?(Path.join(paths.clone, "notes"))
      File.write!(Path.join(paths.clone, "second-attempt"), "another edit")
      stub_tools()
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)

      recovery = Path.join(paths.meta, "recovery")
      assert {:ok, attempts} = File.ls(recovery)
      assert length(attempts) == 2
      first = Enum.find(attempts, &File.exists?(Path.join([recovery, &1, "notes"])))
      assert File.read!(Path.join([recovery, first, tracked])) == "edited compose file"
      assert File.read!(Path.join([recovery, first, "notes"])) == "untracked notes"
      assert File.read!(Path.join([recovery, first, ".git/HEAD"])) == "ref: refs/heads/local-work"
      assert [_] = Path.wildcard(Path.join(recovery, "*/second-attempt"))
      overlay = File.read!(Path.join(paths.meta, "overlay.yml"))
      assert overlay =~ JSON.encode!(recovery)
      assert overlay =~ ~r/target: "\/mnt\/foreman-recovery"\s+read_only: true/
      assert Enum.join(logged()) =~ "/mnt/foreman-recovery/#{first}"

      File.write!(Path.join(paths.clone, "after-success"), "keep in place")
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      assert File.read!(Path.join(paths.clone, "after-success")) == "keep in place"
      assert Enum.sort(File.ls!(recovery)) == Enum.sort(attempts)
    end

    test "refuses a recovery directory that points outside the environment", %{
      ctx: ctx,
      config: config,
      tmp_dir: tmp
    } do
      paths = Env.paths(config, @env_id, "acme/storefront")
      stub_tools(outcome: :error)
      assert {:error, _} = Env.run("env.create", payload(), ctx)
      elsewhere = Path.join(tmp, "elsewhere")
      File.mkdir!(elsewhere)
      File.ln_s!(elsewhere, paths.recovery)
      File.write!(Path.join(paths.clone, "notes"), "keep")
      stub_tools()
      assert {:error, _} = Env.run("env.create", payload(), ctx)
      assert File.ls!(elsewhere) == []
      assert File.read!(Path.join(paths.clone, "notes")) == "keep"
    end

    test "a failure to save the previous checkout stops the fresh clone", %{
      ctx: ctx,
      config: config
    } do
      paths = Env.paths(config, @env_id, "acme/storefront")
      stub_tools(outcome: :error)
      assert {:error, _} = Env.run("env.create", payload(), ctx)
      File.write!(Path.join(paths.clone, "notes"), "keep")
      File.write!(Path.join(paths.meta, "recovery"), "occupied")
      stub_tools()
      assert {:error, message} = Env.run("env.rebuild", payload(), ctx)
      assert message =~ "save the previous workspace"
      assert File.read!(Path.join(paths.clone, "notes")) == "keep"
    end
  end

  describe "rebuild" do
    test "removes the existing container", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      {"devcontainer", params, _} = last_devcontainer()
      assert params.remove_existing
    end
  end

  describe "pull and rebuild" do
    setup %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()
      stub_running_container()
      :ok
    end

    defp pull_payload, do: Map.put(payload(), :pull, true)

    # git that answers like a clone on main with nothing in the way.
    defp git(overrides \\ %{}) do
      answers =
        Map.merge(
          %{
            "symbolic-ref" => {0, "main\n"},
            "status" => {0, ""},
            "fetch" => {0, "From https://github.com/acme/storefront\n"},
            "rev-list" => {0, "0\n"},
            "merge" => {0, "Updating 1111111..2222222\nFast-forward\n"}
          },
          overrides
        )

      fn [command | _] -> Map.fetch!(answers, command) end
    end

    defp git_runs(runs) do
      for {"docker", ["exec" | args], _} <- runs,
          "core.fsmonitor=false" in args,
          do: args |> Enum.drop_while(&(&1 != "core.fsmonitor=false")) |> tl()
    end

    defp up_runs(runs), do: for({"devcontainer", params, _} <- runs, do: params)

    test "fast-forwards the clone inside the container, then rebuilds", %{ctx: ctx} do
      stub_tools(git: git())

      assert {:ok, _} = Env.run("env.rebuild", pull_payload(), ctx)
      runs = runs()

      assert git_runs(runs) == [
               ["symbolic-ref", "--short", "-q", "HEAD"],
               ["status", "--porcelain=v1", "--untracked-files=no"],
               ["fetch", "--no-tags", "origin", "main"],
               ["rev-list", "--count", "FETCH_HEAD..HEAD"],
               ["merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"]
             ]

      # As the remote user, in the container; never on the box.
      assert {"docker", ["exec", "-u", "vscode", "-w", "/workspaces/storefront", "abc123" | _], _} =
               Enum.find(runs, &match?({"docker", ["exec" | _], _}, &1))

      refute Enum.any?(runs, &match?({"git", _, _}, &1))

      merged = Enum.find_index(runs, fn {_, args, _} -> "merge" in args end)
      up = Enum.find_index(runs, &match?({"devcontainer", _, _}, &1))
      assert merged < up, "the new config is used after the pull"

      assert [up] = up_runs(runs)
      assert up.remove_existing
      assert_received {:log, "info", "Fast-forward\n"}
    end

    test "refuses with uncommitted changes, before fetching", %{ctx: ctx} do
      stub_tools(git: git(%{"status" => {0, " M a\n M b\nA  c\n D d\n"}}))

      assert {:error, "4 changed files in the workspace; commit or stash them first",
              %{"pull_failed" => true}} = Env.run("env.rebuild", pull_payload(), ctx)

      runs = runs()
      refute Enum.any?(git_runs(runs), &match?(["fetch" | _], &1))
      assert up_runs(runs) == []
      refute Enum.any?(runs, &match?({"docker", ["compose", "-p", _, "down" | _], _}, &1))
    end

    test "says one changed file", %{ctx: ctx} do
      stub_tools(git: git(%{"status" => {0, " M a\n"}}))

      assert {:error, "1 changed file in the workspace; commit or stash it first", _} =
               Env.run("env.rebuild", pull_payload(), ctx)
    end

    test "refuses when the clone has commits the branch doesn't", %{ctx: ctx} do
      stub_tools(git: git(%{"rev-list" => {0, "2\n"}}))

      assert {:error,
              "the clone has 2 commits that aren't on origin/main; push or rebase them first",
              %{"pull_failed" => true}} = Env.run("env.rebuild", pull_payload(), ctx)

      runs = runs()
      refute Enum.any?(git_runs(runs), &match?(["merge" | _], &1))
      assert up_runs(runs) == []
    end

    test "refuses on another branch", %{ctx: ctx} do
      stub_tools(git: git(%{"symbolic-ref" => {0, "topic\n"}}))

      assert {:error, "the clone has topic checked out, not main; switch back to main first",
              %{"pull_failed" => true}} = Env.run("env.rebuild", pull_payload(), ctx)
    end

    test "refuses with a detached HEAD", %{ctx: ctx} do
      stub_tools(git: git(%{"symbolic-ref" => {1, ""}}))

      assert {:error, "the clone isn't on a branch (detached HEAD); check out main first",
              %{"pull_failed" => true}} = Env.run("env.rebuild", pull_payload(), ctx)
    end

    test "shows git's last lines when the fast-forward fails", %{ctx: ctx} do
      stub_tools(
        git:
          git(%{
            "merge" =>
              {128, "hint: Diverging branches\nfatal: Not possible to fast-forward, aborting.\n"}
          })
      )

      assert {:error, message, %{"pull_failed" => true}} =
               Env.run("env.rebuild", pull_payload(), ctx)

      assert message =~ "couldn't fast-forward to origin/main"
      assert message =~ "fatal: Not possible to fast-forward, aborting."
      assert up_runs(runs()) == []
    end

    test "shows git's last lines when the fetch fails", %{ctx: ctx} do
      stub_tools(git: git(%{"fetch" => {128, "fatal: couldn't find remote ref main\n"}}))

      assert {:error, message, %{"pull_failed" => true}} =
               Env.run("env.rebuild", pull_payload(), ctx)

      assert message =~ "git fetch failed"
      assert message =~ "couldn't find remote ref main"
    end

    test "starts a stopped environment to pull", %{ctx: ctx} do
      stub_tools(git: git())
      counter = :counters.new(1, [])

      stub(DockerMock, :list_containers, fn _ ->
        :counters.add(counter, 1, 1)
        state = if :counters.get(counter, 1) == 1, do: "exited", else: "running"

        {:ok,
         [
           %{
             "Id" => "abc123",
             "State" => state,
             "Labels" => %{"com.docker.compose.service" => "app"}
           }
         ]}
      end)

      assert {:ok, _} = Env.run("env.rebuild", pull_payload(), ctx)
      runs = runs()

      assert [start, rebuild] = up_runs(runs)
      refute start.remove_existing
      assert rebuild.remove_existing

      started = Enum.find_index(runs, &match?({"devcontainer", _, _}, &1))
      fetched = Enum.find_index(runs, fn {_, args, _} -> "fetch" in args end)
      assert started < fetched
    end

    test "a clone made by this rebuild has nothing to pull", %{ctx: ctx, config: config} do
      File.rm_rf!(Path.join([config.envs_root, @env_id, "meta", "spec.term"]))
      stub_tools()

      assert {:ok, _} = Env.run("env.rebuild", pull_payload(), ctx)
      assert git_runs(runs()) == []
    end
  end

  describe "start" do
    test "re-prepares from the saved spec and runs devcontainer up", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()

      assert {:ok, _} =
               Env.run(
                 "env.start",
                 %{env_id: @env_id, slug: "storefront-2", compose_env: %{"X" => "1"}},
                 ctx
               )

      {"devcontainer", args, opts} = last_devcontainer()
      refute args.remove_existing
      assert opts[:env]["X"] == "1"
    end

    # Environments created before the agent reported nodes get one recorded.
    test "reports the node the environment joined the tailnet as", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)

      assert {:ok, result} =
               Env.run(
                 "env.start",
                 %{env_id: @env_id, slug: "storefront-2", compose_env: %{}},
                 ctx
               )

      assert result["tailscale_node_id"] == "nTest1CNTRL"
    end

    # devcontainer up resolves the repo's features again, and a private one
    # needs the registry credentials a create had.
    for {type, extra} <- [{"env.start", %{}}, {"env.restart", %{mode: "all", changed: []}}] do
      test "#{type} hands registry credentials to devcontainer up", %{ctx: ctx} do
        stub_tools()
        {:ok, _} = Env.run("env.create", payload(), ctx)
        _ = runs()
        auth = [%{host: "ghcr.io", username: "machine", token: "ghp_registry"}]

        payload =
          Map.merge(
            %{env_id: @env_id, slug: "storefront-2", compose_env: %{}, registry_auth: auth},
            unquote(Macro.escape(extra))
          )

        assert {:ok, _} = Env.run(unquote(type), payload, ctx)

        [{"devcontainer", args, opts}] = Enum.filter(runs(), &match?({"devcontainer", _, _}, &1))

        refute inspect(args) =~ "ghp_registry"
        assert is_binary(opts[:env]["DOCKER_CONFIG"])
      end
    end

    test "fails clearly for an environment this box never prepared", %{ctx: ctx} do
      assert {:error, message} =
               Env.run(
                 "env.start",
                 %{env_id: @env_id, slug: "storefront-2", compose_env: %{}},
                 ctx
               )

      assert message =~ "rebuild"
    end
  end

  describe "feature version" do
    # The repo's feature, at another version.
    defp feature_at(tmp, version) do
      dir = Path.join(tmp, "feature-#{version}")
      File.cp_r!(Path.expand("../../../../features/src/foreman", __DIR__), dir)
      json = Path.join(dir, "devcontainer-feature.json")

      File.write!(
        json,
        String.replace(File.read!(json), ~r/"version": "[^"]+"/, ~s("version": "#{version}"))
      )

      dir
    end

    defp with_feature(ctx, tmp, version),
      do: put_in(ctx.config.feature_dir, feature_at(tmp, version))

    defp start_payload, do: %{env_id: @env_id, slug: "storefront-2", compose_env: %{}}

    defp restart_payload(mode, changed),
      do: %{env_id: @env_id, slug: "storefront-2", mode: mode, changed: changed, compose_env: %{}}

    defp rebuilt? do
      {"devcontainer", params, _} = last_devcontainer()
      params.remove_existing
    end

    test "is read from the feature the agent ships", %{config: config, tmp_dir: tmp} do
      assert Config.feature_version(config) == "1.1.0"
      assert Config.feature_version(%{config | feature_dir: feature_at(tmp, "2.0.0")}) == "2.0.0"
      assert Config.feature_version(%{config | feature_dir: Path.join(tmp, "missing")}) == nil
    end

    test "a create reports the version it built with", %{ctx: ctx} do
      stub_tools()
      assert {:ok, %{"feature_version" => "1.1.0"}} = Env.run("env.create", payload(), ctx)
    end

    test "a rebuild reports the version it built with", %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)

      assert {:ok, %{"feature_version" => "1.2.0"}} =
               Env.run("env.rebuild", payload(), with_feature(ctx, tmp, "1.2.0"))
    end

    test "a start that reuses the container keeps the version it was built with",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()

      assert {:ok, %{"feature_version" => "1.1.0"}} =
               Env.run("env.start", start_payload(), with_feature(ctx, tmp, "1.2.0"))

      refute rebuilt?()
    end

    test "a start whose container is gone builds one with the shipped version",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      update_container(fn _ -> nil end)
      _ = runs()

      assert {:ok, %{"feature_version" => "1.2.0"}} =
               Env.run("env.start", start_payload(), with_feature(ctx, tmp, "1.2.0"))

      refute rebuilt?()
    end

    # The CLI keeps a container whose setup failed, and starts it next time.
    test "a rebuild that failed after making its container leaves that container's version",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub_tools(outcome: :error)
      {:error, _} = Env.run("env.rebuild", payload(), with_feature(ctx, tmp, "1.2.0"))
      stub_tools()

      assert {:ok, %{"feature_version" => "1.2.0"}} =
               Env.run("env.start", start_payload(), with_feature(ctx, tmp, "1.3.0"))
    end

    test "a start rebuilds a container built with a feature below the floor",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), with_feature(ctx, tmp, "1.0.0"))
      _ = runs()

      assert {:ok, %{"feature_version" => "1.1.0"}} = Env.run("env.start", start_payload(), ctx)
      assert rebuilt?()
      assert Enum.any?(logged(), &(&1 =~ "older Foreman feature"))

      assert {:ok, _} = Env.run("env.start", start_payload(), ctx)
      refute rebuilt?()
    end

    # Made before the agent labelled containers: there's no telling.
    test "a start rebuilds a container with no version", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      update_container(&%{&1 | label: nil})
      _ = runs()

      assert {:ok, %{"feature_version" => "1.1.0"}} = Env.run("env.start", start_payload(), ctx)
      assert rebuilt?()
    end

    test "a start doesn't rebuild when the agent's own feature is below the floor",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      old = with_feature(ctx, tmp, "1.0.0")
      {:ok, _} = Env.run("env.create", payload(), old)
      _ = runs()

      assert {:ok, %{"feature_version" => "1.0.0"}} = Env.run("env.start", start_payload(), old)
      refute rebuilt?()
    end

    defp stub_containers(containers) do
      stub(DockerMock, :list_containers, fn
        ["foreman.env_id=" <> @env_id] ->
          {:ok,
           for {id, service, label} <- containers do
             %{
               "Id" => id,
               "State" => "exited",
               "Labels" => %{
                 "com.docker.compose.service" => service,
                 "foreman.env_id" => @env_id,
                 "foreman.feature_version" => label
               }
             }
           end}

        # The bridge check: on no networks.
        ["com.docker.compose.project=" <> _] ->
          {:ok, []}
      end)
    end

    # The CLI builds the image when it creates the first; a replica scaled
    # up later gets the label of the agent that made it.
    test "a start goes by the oldest of the devcontainer's replicas", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub_containers([{"abc123", "app", "1.0.0"}, {"def456", "app", "1.1.0"}])
      _ = runs()

      assert {:ok, _} = Env.run("env.start", start_payload(), ctx)
      assert rebuilt?()
    end

    test "a start checks the service the repo makes the devcontainer now", %{
      ctx: ctx,
      config: config
    } do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub_containers([{"abc123", "app", "1.1.0"}, {"def456", "db", ""}])

      config_path =
        Path.join([
          config.envs_root,
          @env_id,
          "workspace/storefront/.devcontainer/devcontainer.json"
        ])

      File.write!(
        config_path,
        String.replace(@devcontainer, ~s("service": "app"), ~s("service": "db"))
      )

      _ = runs()

      assert {:ok, _} = Env.run("env.start", start_payload(), ctx)
      assert rebuilt?()
    end

    test "a start fails when it can't tell what the container was built with", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub(DockerMock, :list_containers, fn _ -> {:error, :timeout} end)
      _ = runs()

      assert {:error, message} = Env.run("env.start", start_payload(), ctx)
      assert message =~ "couldn't check"
      refute Enum.any?(runs(), &match?({"devcontainer", _, _}, &1))
    end

    test "restart affected rebuilds below the floor even when the devcontainer isn't affected",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), with_feature(ctx, tmp, "1.0.0"))
      _ = runs()

      assert {:ok, %{"restarted" => ["app"], "feature_version" => "1.1.0"}} =
               Env.run("env.restart", restart_payload("affected", []), ctx)

      assert rebuilt?()

      assert {:ok, _} = Env.run("env.start", start_payload(), ctx)
      refute rebuilt?()
    end

    test "restart all reports the version", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)

      assert {:ok, %{"restarted" => "all", "feature_version" => "1.1.0"}} =
               Env.run("env.restart", restart_payload("all", []), ctx)
    end

    # A refused pull leaves the environment as it was, container and all.
    test "pull and rebuild starts a stopped environment without rebuilding it to check git",
         %{ctx: ctx, tmp_dir: tmp} do
      stub_tools(git: git())
      {:ok, _} = Env.run("env.create", payload(), with_feature(ctx, tmp, "1.0.0"))
      {:ok, _} = Env.run("env.stop", %{env_id: @env_id, slug: "storefront-2"}, ctx)
      _ = runs()

      assert {:ok, %{"feature_version" => "1.1.0"}} =
               Env.run("env.rebuild", Map.put(payload(), :pull, true), ctx)

      assert [start, rebuild] = for({"devcontainer", params, _} <- runs(), do: params)
      refute start.remove_existing
      assert rebuild.remove_existing
    end
  end

  describe "stop" do
    test "stops the compose project by name", %{ctx: ctx} do
      expect(RunnerMock, :run, fn "docker", ["compose", "-p", "storefront-2", "stop"], _ ->
        {:ok, %{status: 0, output: ""}}
      end)

      assert {:ok, %{}} = Env.run("env.stop", %{env_id: @env_id, slug: "storefront-2"}, ctx)
    end
  end

  describe "restart" do
    setup %{ctx: ctx} do
      compose = %{
        "services" => %{
          "app" => %{"environment" => %{"A" => "1"}},
          "neon" => %{"environment" => %{"NEON_API_KEY" => "${NEON_API_KEY}"}},
          "db" => %{}
        }
      }

      stub_tools(compose: compose)
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()
      :ok
    end

    test "affected recreates only services that use a changed variable, then restarts the devcontainer",
         %{
           ctx: ctx
         } do
      assert {:ok, %{"restarted" => ["neon", "app"]}} =
               Env.run(
                 "env.restart",
                 %{
                   env_id: @env_id,
                   slug: "storefront-2",
                   mode: "affected",
                   changed: ["NEON_API_KEY"],
                   compose_env: %{}
                 },
                 ctx
               )

      calls = runs()

      assert Enum.any?(calls, fn {cmd, args, _} ->
               cmd == "docker" and "--force-recreate" in args and List.last(args) == "neon"
             end)

      assert Enum.any?(calls, fn {cmd, args, _} ->
               cmd == "docker" and Enum.take(args, -2) == ["stop", "app"]
             end)

      assert {"devcontainer", _, _} =
               calls |> Enum.reject(&match?({"docker", ["exec" | _], _}, &1)) |> List.last()
    end

    # A sidecar on a private image that isn't on the box yet is pulled by
    # that recreate, before the CLI's up.
    test "affected hands registry credentials to the sidecars it recreates", %{ctx: ctx} do
      auth = [%{host: "ghcr.io", username: "machine", token: "ghp_registry"}]

      assert {:ok, _} =
               Env.run(
                 "env.restart",
                 %{
                   env_id: @env_id,
                   slug: "storefront-2",
                   mode: "affected",
                   changed: ["NEON_API_KEY"],
                   compose_env: %{},
                   registry_auth: auth
                 },
                 ctx
               )

      {"docker", args, opts} =
        Enum.find(runs(), fn {cmd, args, _} -> cmd == "docker" and "--force-recreate" in args end)

      refute inspect(args) =~ "ghp_registry"
      docker_config = opts[:env]["DOCKER_CONFIG"]
      assert is_binary(docker_config)
      refute File.exists?(docker_config)
    end

    # Sidecars are recreated by compose directly, before the CLI's up.
    test "all stops the whole project and brings it back up", %{ctx: ctx} do
      assert {:ok, %{"restarted" => "all"}} =
               Env.run(
                 "env.restart",
                 %{
                   env_id: @env_id,
                   slug: "storefront-2",
                   mode: "all",
                   changed: [],
                   compose_env: %{}
                 },
                 ctx
               )

      calls = runs()

      assert Enum.any?(calls, fn {_, args, _} ->
               args == ["compose", "-p", "storefront-2", "stop"]
             end)

      assert {"devcontainer", _, _} =
               calls |> Enum.reject(&match?({"docker", ["exec" | _], _}, &1)) |> List.last()
    end
  end

  describe "secrets.write" do
    test "replaces the set of files and removes ones no longer sent", %{ctx: ctx, config: config} do
      dir = Path.join(config.secrets_root, @env_id)

      assert {:ok, _} =
               Env.run(
                 "env.secrets.write",
                 %{env_id: @env_id, files: %{"secrets.env" => "a", "notices" => "n"}},
                 ctx
               )

      assert File.read!(Path.join(dir, "notices")) == "n"

      assert {:ok, _} =
               Env.run(
                 "env.secrets.write",
                 %{env_id: @env_id, files: %{"secrets.env" => "b"}},
                 ctx
               )

      assert File.read!(Path.join(dir, "secrets.env")) == "b"
      refute File.exists?(Path.join(dir, "notices"))
    end

    test "leaves files it's told to keep", %{ctx: ctx, config: config} do
      dir = Path.join(config.secrets_root, @env_id)
      files = %{"secrets.env" => "a", "github-token" => "ghu_old"}
      assert {:ok, _} = Env.run("env.secrets.write", %{env_id: @env_id, files: files}, ctx)

      assert {:ok, result} =
               Env.run(
                 "env.secrets.write",
                 %{env_id: @env_id, files: %{"secrets.env" => "b"}, keep: ["github-token"]},
                 ctx
               )

      assert File.read!(Path.join(dir, "secrets.env")) == "b"
      assert File.read!(Path.join(dir, "github-token")) == "ghu_old"
      assert result["kept"] == ["github-token"]
    end

    test "a kept file that was never written stays absent", %{ctx: ctx, config: config} do
      dir = Path.join(config.secrets_root, @env_id)

      assert {:ok, _} =
               Env.run(
                 "env.secrets.write",
                 %{env_id: @env_id, files: %{"secrets.env" => "b"}, keep: ["github-token"]},
                 ctx
               )

      refute File.exists?(Path.join(dir, "github-token"))
    end
  end

  describe "destroy" do
    test "takes the project down with volumes and removes the clone and secrets", %{
      ctx: ctx,
      config: config
    } do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()

      assert {:ok, _} = Env.run("env.destroy", %{env_id: @env_id, slug: "storefront-2"}, ctx)

      assert Enum.any?(runs(), fn {_, args, _} ->
               args == ["compose", "-p", "storefront-2", "down", "--volumes", "--remove-orphans"]
             end)

      refute File.exists?(Path.join(config.envs_root, @env_id))
      refute File.exists?(Path.join(config.secrets_root, @env_id))
    end
  end

  describe "git_status" do
    test "asks git inside the container, never on the box", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()

      stub(DockerMock, :list_containers, fn ["foreman.env_id=" <> @env_id] ->
        {:ok,
         [
           %{
             "Id" => "abc123",
             "State" => "running",
             "Labels" => %{"com.docker.compose.service" => "app", "foreman.env_id" => @env_id}
           }
         ]}
      end)

      stub(RunnerMock, :run, fn "docker",
                                [
                                  "exec",
                                  "-u",
                                  "vscode",
                                  "-w",
                                  "/workspaces/storefront",
                                  "abc123",
                                  "git",
                                  "-c",
                                  "safe.directory=*",
                                  "-c",
                                  "core.fsmonitor=false" | rest
                                ],
                                _ ->
        case rest do
          ["status" | _] ->
            {:ok,
             %{status: 0, output: "## main...origin/main [ahead 2]\n M lib/a.ex\n?? new.txt\n"}}

          ["log" | _] ->
            {:ok, %{status: 0, output: "abc one\ndef two\n"}}

          ["rev-parse", "HEAD"] ->
            {:ok, %{status: 0, output: @head <> "\n"}}

          ["merge-base", "HEAD", "@{upstream}"] ->
            {:ok, %{status: 0, output: @base <> "\n"}}
        end
      end)

      assert {:ok, result} =
               Env.run("env.git_status", %{env_id: @env_id, slug: "storefront-2"}, ctx)

      assert result == %{
               "branch" => "main",
               "changed_files" => 2,
               "unpushed_commits" => 2,
               "clean" => false,
               "head" => @head,
               "base" => @base,
               "ahead" => 2
             }
    end

    test "a branch with no upstream has no base, and git's other output is ignored", %{ctx: ctx} do
      stub_tools()
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()
      stub_running_container()

      stub(RunnerMock, :run, fn "docker", args, _ ->
        case Enum.drop_while(args, &(&1 != "core.fsmonitor=false")) |> tl() do
          ["status" | _] -> {:ok, %{status: 0, output: "## topic\n"}}
          ["log" | _] -> {:ok, %{status: 0, output: ""}}
          # Whatever runs in the container answers for git there.
          ["rev-parse", "HEAD"] -> {:ok, %{status: 0, output: "../../etc\n"}}
          ["merge-base" | _] -> {:ok, %{status: 128, output: "fatal: no upstream configured\n"}}
        end
      end)

      assert {:ok, result} =
               Env.run("env.git_status", %{env_id: @env_id, slug: "storefront-2"}, ctx)

      assert %{"branch" => "topic", "head" => nil, "base" => nil, "ahead" => 0} = result
    end
  end

  describe "connect hooks" do
    defp orca_hooks(extra \\ fn _ -> nil end) do
      fn args ->
        extra.(args) ||
          case args do
            ["list"] -> {0, "orca\n"}
            ["orca", "describe"] -> {0, @describe <> "\n"}
            ["orca", "run", "desktop"] -> {0, "restarting orca\n" <> @offer <> "\n"}
          end
      end
    end

    defp connect_payload(action \\ "desktop"),
      do: %{env_id: @env_id, slug: "storefront-2", hook: "orca", action: action}

    test "an up reports the hooks the container has, as its remote user", %{ctx: ctx} do
      stub_tools(connect: orca_hooks())

      assert {:ok, result} = Env.run("env.create", payload(), ctx)

      assert result["connect"] == [
               %{
                 "name" => "orca",
                 "label" => "Orca",
                 "actions" => [
                   %{
                     "id" => "desktop",
                     "label" => "Pair a desktop",
                     "confirm" => "Orca restarts."
                   }
                 ]
               }
             ]

      execs = for {"docker", ["exec" | args], opts} <- runs(), do: {args, opts}
      [{list, list_opts}, {describe, describe_opts}] = Enum.take(execs, -2)

      assert ["-u", "vscode", "-w", "/workspaces/storefront", "abc123", "sh", "-c", _] = list

      assert [
               "-u",
               "vscode",
               "-w",
               "/workspaces/storefront",
               "abc123",
               "sh",
               "-c",
               wrapper,
               "sh",
               "30",
               hook,
               "describe"
             ] = describe

      assert hook == @hook_dir <> "/orca"
      # Bounded inside the container too: a timeout here only stops docker exec.
      assert wrapper =~ "timeout"
      assert list_opts[:timeout] && describe_opts[:timeout]
    end

    test "a container without hooks reports none", %{ctx: ctx} do
      stub_tools()
      assert {:ok, %{"connect" => []}} = Env.run("env.create", payload(), ctx)
    end

    test "takes the last line of a describe, after whatever the hook printed first", %{ctx: ctx} do
      stub_tools(
        connect:
          orca_hooks(fn
            ["orca", "describe"] -> {0, "warming up\n" <> @describe <> "\n\n"}
            _ -> nil
          end)
      )

      assert {:ok, %{"connect" => [%{"name" => "orca"}]}} =
               Env.run("env.create", payload(), ctx)
    end

    test "leaves out a hook whose describe fails or doesn't fit, and says so", %{ctx: ctx} do
      stub_tools(
        connect:
          orca_hooks(fn
            ["list"] -> {0, "broken\nnoisy\nNot-A-Name\norca\n"}
            ["broken", "describe"] -> {1, "boom\n"}
            ["noisy", "describe"] -> {0, ~s({"label":"Noisy","actions":"all of them"})}
            _ -> nil
          end)
      )

      assert {:ok, %{"connect" => [%{"name" => "orca"}]}} =
               Env.run("env.create", payload(), ctx)

      log = Enum.join(logged())
      assert log =~ "connect hook broken"
      assert log =~ "connect hook noisy"
      refute log =~ "Not-A-Name"
    end

    test "a container it can't list hooks in reports none", %{ctx: ctx} do
      stub_tools(
        connect:
          orca_hooks(fn
            ["list"] -> {126, "OCI runtime exec failed: exec: \"sh\": not found\n"}
            _ -> nil
          end)
      )

      assert {:ok, %{"connect" => []}} = Env.run("env.create", payload(), ctx)
    end

    test "a start reports them too, and so does restarting everything", %{ctx: ctx} do
      stub_tools(connect: orca_hooks())
      {:ok, _} = Env.run("env.create", payload(), ctx)

      start = %{env_id: @env_id, slug: "storefront-2", compose_env: %{}}
      assert {:ok, %{"connect" => [%{"name" => "orca"}]}} = Env.run("env.start", start, ctx)

      restart = Map.merge(start, %{mode: "all", changed: []})
      assert {:ok, %{"connect" => [%{"name" => "orca"}]}} = Env.run("env.restart", restart, ctx)

      # Every up reports them, so a result without them is an older agent's.
      affected = Map.merge(start, %{mode: "affected", changed: ["APP_SECRET"]})
      assert {:ok, %{"connect" => [%{"name" => "orca"}]}} = Env.run("env.restart", affected, ctx)
    end

    test "env.connect runs the action and hands back the offer, without logging it", %{ctx: ctx} do
      stub_tools(connect: orca_hooks())
      {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()
      _ = logged()
      stub_running_container()

      assert {:ok, result} = Env.run("env.connect", connect_payload(), ctx)

      assert result == %{
               "offer" => %{
                 "value" => "orca://pair?code=s3cretc0de",
                 "qr" => false,
                 "note" => "Paste it into Orca."
               }
             }

      [{"docker", args, opts}] = runs()

      assert [
               "exec",
               "-u",
               "vscode",
               "-w",
               "/workspaces/storefront",
               "abc123",
               "sh",
               "-c",
               _,
               "sh",
               secs,
               hook,
               "run",
               "desktop"
             ] = args

      assert hook == @hook_dir <> "/orca"
      # The container's own timeout goes first, then docker exec's.
      assert String.to_integer(secs) * 1000 < opts[:timeout]
      assert opts[:timeout] >= :timer.minutes(3)
      refute Enum.join(logged()) =~ "s3cretc0de"
      refute_received {:log, _, _}
    end

    test "env.connect shows a failing hook's own explanation, and nothing else", %{ctx: ctx} do
      stub_tools(
        connect:
          orca_hooks(fn
            ["orca", "run", "desktop"] ->
              {1, "code: s3cretc0de\n" <> ~s({"error":"no pairing offer after 120s"}) <> "\n"}

            _ ->
              nil
          end)
      )

      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub_running_container()

      assert {:error, message} = Env.run("env.connect", connect_payload(), ctx)
      assert message =~ "orca"
      assert message =~ "no pairing offer after 120s"
      refute message =~ "s3cretc0de"
    end

    # It could have printed the secret before it failed.
    test "env.connect doesn't repeat what a failing hook printed", %{ctx: ctx} do
      stub_tools(
        connect:
          orca_hooks(fn
            ["orca", "run", "desktop"] -> {1, "code: s3cretc0de\ncleanup failed\n"}
            _ -> nil
          end)
      )

      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub_running_container()

      assert {:error, message} = Env.run("env.connect", connect_payload(), ctx)
      assert message =~ "connect hook orca failed"
      refute message =~ "s3cretc0de"
      refute message =~ "cleanup"
    end

    test "env.connect doesn't repeat output it can't read: it could hold the secret", %{ctx: ctx} do
      stub_tools(
        connect:
          orca_hooks(fn
            ["orca", "run", "desktop"] -> {0, "code: s3cretc0de\n"}
            _ -> nil
          end)
      )

      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub_running_container()

      assert {:error, message} = Env.run("env.connect", connect_payload(), ctx)
      assert message =~ "orca"
      refute message =~ "s3cretc0de"
    end

    # The wrapper the agent runs hooks under, run here for real.
    test "a hook runs under timeout, and doesn't run at all without it", %{tmp_dir: tmp} do
      wrapper = Env.hook_wrapper()

      empty = Path.join(tmp, "no-timeout")
      File.mkdir_p!(empty)

      {out, status} =
        System.cmd("/bin/sh", ["-c", wrapper, "sh", "5", "/bin/echo", "ran"],
          env: [{"PATH", empty}],
          stderr_to_stdout: true
        )

      assert status != 0
      refute out =~ "ran"
      assert {:ok, %{"error" => error}} = out |> String.trim() |> JSON.decode()
      assert error =~ "timeout"

      if timeout = System.find_executable("timeout") do
        bin = Path.join(tmp, "bin")
        File.mkdir_p!(bin)
        File.ln_s!(timeout, Path.join(bin, "timeout"))
        started = System.monotonic_time(:millisecond)

        {_out, status} =
          System.cmd("/bin/sh", ["-c", wrapper, "sh", "1", "/bin/sleep", "30"],
            env: [{"PATH", bin <> ":/bin:/usr/bin"}]
          )

        assert status != 0
        assert System.monotonic_time(:millisecond) - started < 10_000
      end
    end

    test "env.connect needs the environment running", %{ctx: ctx} do
      stub_tools(connect: orca_hooks())
      {:ok, _} = Env.run("env.create", payload(), ctx)
      stub(DockerMock, :list_containers, fn _ -> {:ok, []} end)

      assert {:error, message} = Env.run("env.connect", connect_payload(), ctx)
      assert message =~ "isn't running"
    end
  end

  # Asked for by environment (git status) and by compose project (the
  # check of the containers' networks after an up).
  defp stub_running_container do
    stub(DockerMock, :list_containers, fn [_label] ->
      {:ok,
       [
         %{
           "Id" => "abc123",
           "State" => "running",
           "Labels" => %{"com.docker.compose.service" => "app", "foreman.env_id" => @env_id}
         }
       ]}
    end)
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end
end
