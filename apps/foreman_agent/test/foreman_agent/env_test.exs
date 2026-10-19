defmodule ForemanAgent.EnvTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, Env, RunnerMock}
  alias ForemanAgent.Env.Policy

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

  setup :verify_on_exit!

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

    File.mkdir_p!(config.envs_root)
    File.mkdir_p!(config.secrets_root)

    test_pid = self()
    log = fn stream, data -> send(test_pid, {:log, stream, data}) end

    %{config: config, ctx: %{config: config, runner: RunnerMock, docker: DockerMock, log: log}}
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

  # A runner that behaves like git, docker compose and the devcontainer CLI.
  defp stub_tools(opts \\ []) do
    test_pid = self()
    compose = Keyword.get(opts, :compose, %{"services" => %{"app" => %{}, "db" => %{}}})
    devcontainer = Keyword.get(opts, :devcontainer, @devcontainer)
    outcome = Keyword.get(opts, :outcome, :success)
    docker_info = Keyword.get(opts, :docker_info, {:ok, %{"DefaultRuntime" => "runc"}})
    tailscale = Keyword.get(opts, :tailscale, fn -> {0, @joined} end)

    stub(DockerMock, :info, fn -> docker_info end)

    resolved =
      Keyword.get(opts, :resolved, %{
        "configuration" => %{},
        "mergedConfiguration" => %{"capAdd" => ["NET_ADMIN", "NET_RAW"]},
        "featuresConfiguration" => %{"featureSets" => []}
      })

    stub(RunnerMock, :run, fn command, args, run_opts ->
      send(test_pid, {:run, command, args, run_opts})

      case {command, args} do
        {"git", args} ->
          dest = List.last(args)
          File.mkdir_p!(Path.join(dest, ".git/info"))
          File.mkdir_p!(Path.join(dest, ".devcontainer"))
          File.write!(Path.join(dest, ".devcontainer/devcontainer.json"), devcontainer)
          File.write!(Path.join(dest, ".devcontainer/docker-compose.yml"), "services: {}\n")
          {:ok, %{status: 0, output: "Cloning into '#{dest}'...\n"}}

        {"docker", ["compose" | rest]} ->
          fake_compose(rest, compose)

        {"devcontainer", ["read-configuration" | _]} ->
          log = ~s({"type":"text","level":3,"timestamp":1,"text":"Resolving features"}\n)
          {:ok, %{status: 0, output: log <> JSON.encode!(resolved) <> "\n"}}

        {"devcontainer", _} ->
          run_opts[:on_output].(
            ~s({"type":"text","level":3,"timestamp":1,"text":"Building image"}\n)
          )

          run_opts[:on_output].(
            ~s({"type":"text","level":2,"timestamp":1,"text":"debug noise"}\n)
          )

          # The CLI logs the merged compose config, interpolated secrets and all.
          run_opts[:on_output].(
            ~s({"type":"text","level":3,"timestamp":1,"text":"name: storefront-2\\nservices:\\n  app:\\n    environment:\\n      NEON_API_KEY: neon_secret"}\n)
          )

          run_opts[:on_output].(
            ~s({"type":"raw","level":3,"timestamp":1,"text":"\\u001b[1m\\u001b[31mColored\\u001b[39m\\u001b[22m\\n"}\n)
          )

          up_result(outcome, run_opts)

        {"docker", ["exec", "-u", "0", _container, "tailscale" | _]} ->
          {status, output} = tailscale.()
          {:ok, %{status: status, output: output}}

        {"docker", ["exec" | rest]} ->
          container_git(Keyword.get(opts, :git), rest, run_opts)

        other ->
          flunk("unexpected command: #{inspect(other)}")
      end
    end)
  end

  defp up_result(:success, _run_opts) do
    result =
      ~s({"outcome":"success","containerId":"abc123","composeProjectName":"storefront-2","remoteUser":"vscode","remoteWorkspaceFolder":"/workspaces/storefront"}\n)

    {:ok, %{status: 0, output: result}}
  end

  defp up_result(:error, _run_opts) do
    {:ok,
     %{
       status: 1,
       output:
         ~s({"outcome":"error","message":"build failed","description":"An error occurred"}\n)
     }}
  end

  # The CLI exits without writing an outcome line: what it printed streams
  # to the log, and the runner keeps the same bytes.
  defp up_result({:exit, status, stream}, run_opts) do
    run_opts[:on_output].(stream)
    {:ok, %{status: status, output: stream}}
  end

  defp fake_compose(args, compose) do
    if "config" in args do
      out = args |> Enum.drop_while(&(&1 != "-o")) |> Enum.at(1)
      File.write!(out, JSON.encode!(compose))
    end

    {:ok, %{status: 0, output: ""}}
  end

  # `answer` takes git's arguments (after the -c options) and returns
  # {status, output}.
  defp container_git(nil, rest, _run_opts), do: flunk("unexpected docker exec: #{inspect(rest)}")

  defp container_git(answer, rest, run_opts) do
    {status, output} = answer.(rest |> Enum.drop_while(&(&1 != "core.fsmonitor=false")) |> tl())
    if status == 0, do: run_opts[:on_output].(output)
    {:ok, %{status: status, output: output}}
  end

  defp up_result({:error, message}, _run_opts) do
    failure = %{"outcome" => "error", "message" => message, "description" => ""}
    {:ok, %{status: 1, output: JSON.encode!(failure) <> "\n"}}
  end

  defp runs do
    receive_all([])
  end

  # The last devcontainer CLI run; asking Tailscale for the node comes after.
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

  # The devcontainer CLI's --log-format json output for lines a lifecycle
  # command printed.
  defp raw_log(lines) do
    Enum.map_join(lines, &(JSON.encode!(%{"type" => "raw", "level" => 3, "text" => &1}) <> "\n"))
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

      # The repo's compose files are read before compose reads anything
      # (ComposeScan), so compose itself runs twice: services, then policy.
      [git, _services, _policy, read_config, up, _tailscale] = runs()

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

      {"devcontainer", up_args, up_opts} = up
      assert ["up", "--workspace-folder", ^clone | _] = up_args
      assert arg(up_args, "--override-config") == Path.join(meta, "devcontainer.json")
      assert arg(up_args, "--id-label") == "foreman.env_id=#{@env_id}"

      assert JSON.decode!(arg(up_args, "--additional-features")) == %{
               "./.foreman/feature" => %{"tailscale" => true}
             }

      refute Enum.any?(up_args, &(&1 =~ "neon_secret"))
      assert up_opts[:env]["NEON_API_KEY"] == "neon_secret"
      assert up_opts[:env]["COMPOSE_PROJECT_NAME"] == "storefront-2"

      # What features ask for is checked first, against the same config.
      {"devcontainer", ["read-configuration" | rc_args], rc_opts} = read_config
      assert "--include-merged-configuration" in rc_args

      for flag <- ["--workspace-folder", "--config", "--override-config", "--additional-features"] do
        assert arg(rc_args, flag) == arg(up_args, flag)
      end

      assert rc_opts[:env] == up_opts[:env]

      override = meta |> Path.join("devcontainer.json") |> File.read!() |> JSON.decode!()
      refute Map.has_key?(override, "initializeCommand")

      assert override["dockerComposeFile"] == [
               Path.join(clone, ".devcontainer/docker-compose.yml"),
               Path.join(meta, "overlay.yml")
             ]

      overlay = File.read!(Path.join(meta, "overlay.yml"))
      assert overlay =~ "ports: !reset []"
      assert overlay =~ ~s(source: "#{secrets}")

      assert File.exists?(
               Path.join(clone, ".devcontainer/.foreman/feature/devcontainer-feature.json")
             )

      assert File.read!(Path.join(clone, ".git/info/exclude")) =~ "/.devcontainer/.foreman/"

      assert_received {:log, "info", "Building image\n"}
      assert_received {:log, "info", "Colored\n"}
      refute_received {:log, _, "debug noise\n"}
      refute_received {:log, _, "name: storefront-2" <> _}
    end

    test "reports the node the environment joined the tailnet as", %{ctx: ctx} do
      stub_tools()

      assert {:ok, result} = Env.run("env.create", payload(), ctx)
      assert result["tailscale_node_id"] == "nTest1CNTRL"

      # Asked inside the devcontainer, after it's up.
      {"docker", args, opts} = List.last(runs())

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
      {"devcontainer", args, _} = last_devcontainer()
      assert "--no-lockfile" in args

      clone = Path.join([ctx.config.envs_root, @env_id, "workspace", "storefront"])
      File.write!(Path.join(clone, ".devcontainer/devcontainer-lock.json"), "{}")
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      {"devcontainer", args, _} = last_devcontainer()
      refute "--no-lockfile" in args
    end

    test "passes dotfiles to the devcontainer CLI", %{ctx: ctx} do
      stub_tools()

      dotfiles = %{
        "repository" => "https://github.com/mona/dotfiles.git",
        "install_command" => "./install.sh"
      }

      assert {:ok, _} = Env.run("env.create", payload(%{"dotfiles" => dotfiles}), ctx)

      {"devcontainer", args, _} = last_devcontainer()
      assert arg(args, "--dotfiles-repository") == "https://github.com/mona/dotfiles.git"
      assert arg(args, "--dotfiles-install-command") == "./install.sh"
    end

    test "adds the user's features alongside Foreman's", %{ctx: ctx} do
      stub_tools()
      orca = %{"ghcr.io/ntodd/devcontainer-features/orca:1" => %{"server" => true}}

      assert {:ok, _} = Env.run("env.create", payload(%{"features" => orca}), ctx)

      [_git, _services, _policy, {"devcontainer", rc_args, _}, {"devcontainer", up_args, _}, _ts] =
        runs()

      expected =
        Map.put(orca, "./.foreman/feature", %{"tailscale" => true})

      assert JSON.decode!(arg(rc_args, "--additional-features")) == expected
      assert JSON.decode!(arg(up_args, "--additional-features")) == expected
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

      assert JSON.decode!(arg(up_args, "--additional-features")) == %{
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

    test "names the user's feature when the policy refuses it", %{ctx: ctx} do
      ref = "ghcr.io/mona/features/root:1"

      stub_tools(
        resolved: %{
          "configuration" => %{},
          "mergedConfiguration" => %{"privileged" => true},
          "featuresConfiguration" => %{
            "featureSets" => [
              %{
                "sourceInformation" => %{"userFeatureId" => ref},
                "features" => [%{"id" => "root", "privileged" => true}]
              }
            ]
          }
        }
      )

      assert {:error, message} =
               Env.run("env.create", payload(%{"features" => %{ref => %{}}}), ctx)

      assert message =~ "your feature #{ref}"
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

    test "stops when the policy refuses the compose config", %{ctx: ctx} do
      compose = %{
        "services" => %{
          "app" => %{
            "volumes" => [%{"type" => "bind", "source" => "/etc", "target" => "/host-etc"}]
          }
        }
      }

      stub_tools(compose: compose)

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "/etc"
      refute Enum.any?(runs(), &match?({"devcontainer", _, _}, &1))
    end

    test "refuses a feature that asks for privileged before anything runs", %{ctx: ctx} do
      stub_tools(
        resolved: %{
          "configuration" => %{},
          "mergedConfiguration" => %{"privileged" => true},
          "featuresConfiguration" => %{
            "featureSets" => [
              %{
                "sourceInformation" => %{"userFeatureId" => "ghcr.io/acme/features/sneaky:1"},
                "features" => [%{"id" => "sneaky", "privileged" => true}]
              }
            ]
          }
        }
      )

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "ghcr.io/acme/features/sneaky:1"
      refute Enum.any?(runs(), &match?({"devcontainer", ["up" | _], _}, &1))
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

    test "reports devcontainer CLI failures", %{ctx: ctx} do
      stub_tools(outcome: :error)
      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "build failed"
    end

    test "says when devcontainer up exits without reporting a result", %{ctx: ctx} do
      stub_tools(outcome: {:exit, 1, raw_log(["Running postCreateCommand"])})

      assert {:error, message} = Env.run("env.create", payload(), ctx)

      assert message =~
               "devcontainer up exited with status 1 without reporting a result. " <>
                 "Its last output is below."

      assert message =~ "Running postCreateCommand"
      refute message =~ ~s("type":)
    end

    test "names the signal that stopped devcontainer up", %{ctx: ctx} do
      stub_tools(outcome: {:exit, 137, raw_log(["Running postCreateCommand"])})

      assert {:error, message} = Env.run("env.create", payload(), ctx)

      assert message =~
               "devcontainer up was killed by SIGKILL (status 137) without reporting a result"
    end

    test "collapses spinner frames and cursor redraws in the log and the error", %{ctx: ctx} do
      frames =
        for i <- 0..39 do
          glyph = Enum.at(~w(◐ ◓ ◑ ◒), rem(i, 4))
          dots = String.duplicate(".", div(i, 10))
          "\e[1G\e[J#{glyph}  Cloning repository…#{dots}"
        end

      lines =
        ["◇  Source: https://github.com/stablyai/orca.git"] ++
          Enum.take(frames, 20) ++ ["\e[1D", "\e[0K"] ++ Enum.drop(frames, 20)

      stub_tools(outcome: {:exit, 1, raw_log(lines)})

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "Source: https://github.com/stablyai/orca.git"
      assert length(String.split(message, "Cloning repository")) == 2

      logged = logged()
      assert Enum.count(logged, &(&1 =~ "Cloning repository")) == 1
      assert "◐  Cloning repository…\n" in logged
      refute "\n" in logged
    end

    test "collapses spinner frames that arrive in one log entry", %{ctx: ctx} do
      frames =
        for i <- 0..19, do: "#{Enum.at(~w(◐ ◓ ◑ ◒), rem(i, 4))}  Cloning repository…\n"

      stub_tools(outcome: {:exit, 1, raw_log([Enum.join(["Source: repo\n" | frames])])})

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "Source: repo"
      assert length(String.split(message, "Cloning repository")) == 2
    end

    test "shows only the last of frames redrawn on one line", %{ctx: ctx} do
      redraws =
        Enum.map_join(0..19, fn i ->
          "\e[1G\e[J#{Enum.at(~w(◐ ◓ ◑ ◒), rem(i, 4))}  Cloning repository…"
        end)

      lines = ["Source: repo\n" <> redraws, "\r", "\e[1G\e[J◐  Cloning repository…."]
      stub_tools(outcome: {:exit, 1, raw_log(lines)})

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "Source: repo\n◒  Cloning repository…"
      assert length(String.split(message, "Cloning repository")) == 2

      logged = logged()
      assert Enum.count(logged, &(&1 =~ "Cloning repository")) == 1
      refute "\n" in logged
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

    test "the devcontainer CLI never adds GPUs of its own", %{ctx: ctx} do
      # hostRequirements.gpu (in devcontainer.json or an image's metadata)
      # makes the CLI reserve GPUs after the policy has checked compose.
      stub_tools(
        devcontainer:
          ~s({"dockerComposeFile": "docker-compose.yml", "service": "app", "hostRequirements": {"gpu": true}})
      )

      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      {"devcontainer", up_args, _} = last_devcontainer()
      assert ["up" | _] = up_args
      assert arg(up_args, "--gpu-availability") == "none"
    end

    test "refuses to start on a box whose default Docker runtime is nvidia", %{ctx: ctx} do
      stub_tools(docker_info: {:ok, %{"DefaultRuntime" => "nvidia"}})

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "default runtime"
      refute Enum.any?(runs(), &match?({"devcontainer", ["up" | _], _}, &1))
    end

    test "checks a service's runtime against the runtimes Docker has", %{ctx: ctx, config: config} do
      stub_tools(
        compose: %{"services" => %{"app" => %{"runtime" => "gpu"}, "db" => %{}}},
        docker_info:
          {:ok,
           %{
             "DefaultRuntime" => "runc",
             "Runtimes" => %{"gpu" => %{"path" => "/usr/bin/nvidia-container-runtime"}}
           }}
      )

      ctx = put_in(ctx.config.policy_rules, Map.put(config.policy_rules, :compose_keys, :allow))

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "nvidia runtime"
    end

    test "refuses to start when it can't tell what Docker's default runtime is", %{ctx: ctx} do
      stub_tools(docker_info: {:error, :econnrefused})

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "default runtime"
      refute Enum.any?(runs(), &match?({"devcontainer", ["up" | _], _}, &1))
    end

    test "says the box needs the NVIDIA Container Toolkit when Docker has no GPU driver", %{
      ctx: ctx,
      config: config
    } do
      gpu = %{"driver" => "nvidia", "count" => -1, "capabilities" => ["gpu", "video", "utility"]}

      compose = %{
        "services" => %{
          "app" => %{"deploy" => %{"resources" => %{"reservations" => %{"devices" => [gpu]}}}}
        }
      }

      stub_tools(
        compose: compose,
        outcome:
          {:error,
           ~s(Error response from daemon: could not select device driver "nvidia" with capabilities: [[gpu video utility]])}
      )

      ctx = put_in(ctx.config.policy_rules, Map.put(config.policy_rules, :gpu, :allow))

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "NVIDIA Container Toolkit"
      assert message =~ "could not select device driver"
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

    test "writes registry credentials to a throwaway docker config, never argv", %{ctx: ctx} do
      stub_tools()
      auth = [%{"host" => "ghcr.io", "username" => "machine", "token" => "ghp_registry"}]

      assert {:ok, _} = Env.run("env.create", payload(%{"registry_auth" => auth}), ctx)

      [{"devcontainer", _, rc_opts}, {"devcontainer", args, opts}] =
        Enum.filter(runs(), &match?({"devcontainer", _, _}, &1))

      refute Enum.any?(args, &(&1 =~ "ghp_registry"))
      docker_config = opts[:env]["DOCKER_CONFIG"]
      assert is_binary(docker_config)
      assert rc_opts[:env]["DOCKER_CONFIG"] == docker_config
      refute File.exists?(docker_config)
    end
  end

  describe "rebuild" do
    test "removes the existing container", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      {"devcontainer", args, _} = last_devcontainer()
      assert "--remove-existing-container" in args
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

    defp up_runs(runs), do: for({"devcontainer", ["up" | args], _} <- runs, do: args)

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
      read = Enum.find_index(runs, &match?({"devcontainer", ["read-configuration" | _], _}, &1))
      assert merged < read, "the new config is read after the pull"

      assert [up] = up_runs(runs)
      assert "--remove-existing-container" in up
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
      refute "--remove-existing-container" in start
      assert "--remove-existing-container" in rebuild

      started = Enum.find_index(runs, &match?({"devcontainer", ["up" | _], _}, &1))
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
      refute "--remove-existing-container" in args
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

      assert {"devcontainer", _, _} = List.last(calls)
    end

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

      assert {"devcontainer", _, _} = List.last(calls)
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

  defp stub_running_container do
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
  end

  defp arg(args, flag) do
    args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end
end
