defmodule ForemanAgent.EnvTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, Env, RunnerMock}
  alias ForemanAgent.Env.Policy

  @moduletag :tmp_dir

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

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
          if "config" in rest do
            out = rest |> Enum.drop_while(&(&1 != "-o")) |> Enum.at(1)
            File.write!(out, JSON.encode!(compose))
          end

          {:ok, %{status: 0, output: ""}}

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

          case outcome do
            :success ->
              result =
                ~s({"outcome":"success","containerId":"abc123","composeProjectName":"storefront-2","remoteUser":"vscode","remoteWorkspaceFolder":"/workspaces/storefront"}\n)

              {:ok, %{status: 0, output: result}}

            :error ->
              {:ok,
               %{
                 status: 1,
                 output:
                   ~s({"outcome":"error","message":"build failed","description":"An error occurred"}\n)
               }}
          end

        other ->
          flunk("unexpected command: #{inspect(other)}")
      end
    end)
  end

  defp runs do
    receive_all([])
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
      [git, _services, _policy, read_config, up] = runs()

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

    test "doesn't leave a feature lockfile behind unless the repo keeps one", %{ctx: ctx} do
      stub_tools()
      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      {"devcontainer", args, _} = List.last(runs())
      assert "--no-lockfile" in args

      clone = Path.join([ctx.config.envs_root, @env_id, "workspace", "storefront"])
      File.write!(Path.join(clone, ".devcontainer/devcontainer-lock.json"), "{}")
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      {"devcontainer", args, _} = List.last(runs())
      refute "--no-lockfile" in args
    end

    test "passes dotfiles to the devcontainer CLI", %{ctx: ctx} do
      stub_tools()

      dotfiles = %{
        "repository" => "https://github.com/mona/dotfiles.git",
        "install_command" => "./install.sh"
      }

      assert {:ok, _} = Env.run("env.create", payload(%{"dotfiles" => dotfiles}), ctx)

      {"devcontainer", args, _} = List.last(runs())
      assert arg(args, "--dotfiles-repository") == "https://github.com/mona/dotfiles.git"
      assert arg(args, "--dotfiles-install-command") == "./install.sh"
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
      {"devcontainer", args, _} = List.last(runs())
      assert "--remove-existing-container" in args
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

      {"devcontainer", args, opts} = List.last(runs())
      refute "--remove-existing-container" in args
      assert opts[:env]["X"] == "1"
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
        if "status" in rest do
          {:ok,
           %{status: 0, output: "## main...origin/main [ahead 2]\n M lib/a.ex\n?? new.txt\n"}}
        else
          {:ok, %{status: 0, output: "abc one\ndef two\n"}}
        end
      end)

      assert {:ok, result} =
               Env.run("env.git_status", %{env_id: @env_id, slug: "storefront-2"}, ctx)

      assert result == %{
               "branch" => "main",
               "changed_files" => 2,
               "unpushed_commits" => 2,
               "clean" => false
             }
    end
  end

  defp arg(args, flag) do
    args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end
end
