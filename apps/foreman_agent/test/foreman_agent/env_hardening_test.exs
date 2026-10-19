defmodule ForemanAgent.EnvHardeningTest do
  @moduledoc """
  Environment operations against odd but legitimate repos, partial
  failures, and compose features that would otherwise get past the policy.
  Git, docker compose and the devcontainer CLI are stubbed.
  """
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, Env, RunnerMock}
  alias ForemanAgent.Env.Policy

  @moduletag :tmp_dir
  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  @resolved %{
    "configuration" => %{},
    "mergedConfiguration" => %{},
    "featuresConfiguration" => %{"featureSets" => []}
  }

  @success ~s({"outcome":"success","containerId":"c1","remoteUser":"vscode","remoteWorkspaceFolder":"/w"}\n)

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
            "tailscale" => %{"enabled" => true}
          },
          overrides
        )
      )

    cmd.payload
  end

  defp standard_layout(
         devcontainer \\ ~s({"dockerComposeFile": "docker-compose.yml", "service": "app"})
       ) do
    fn dest ->
      File.mkdir_p!(Path.join(dest, ".devcontainer"))
      File.write!(Path.join(dest, ".devcontainer/devcontainer.json"), devcontainer)
      File.write!(Path.join(dest, ".devcontainer/docker-compose.yml"), "services: {}\n")
    end
  end

  # `layout` writes the clone. `compose` is the parsed `config` output, or
  # `{:fail, output}`; it's a function so a test can change it between calls.
  defp stub_tools(layout, compose, opts \\ []) do
    test_pid = self()
    devcontainer_missing = Keyword.get(opts, :devcontainer_missing, false)

    stub(RunnerMock, :run, fn command, args, _run_opts ->
      send(test_pid, {:run, command, args})

      case {command, args} do
        {"git", args} ->
          dest = List.last(args)
          File.mkdir_p!(Path.join(dest, ".git/info"))
          layout.(dest)
          {:ok, %{status: 0, output: ""}}

        {"docker", ["compose" | rest]} ->
          fake_compose(rest, compose.())

        {"devcontainer", _} when devcontainer_missing ->
          {:error, {:not_found, "devcontainer"}}

        {"devcontainer", ["read-configuration" | _]} ->
          {:ok, %{status: 0, output: JSON.encode!(@resolved) <> "\n"}}

        {"devcontainer", _} ->
          {:ok, %{status: 0, output: @success}}

        {"docker", ["exec", "-u", "0", _container, "tailscale" | _]} ->
          {:ok, %{status: 0, output: ~s({"BackendState":"Running","Self":{"ID":"nTest1CNTRL"}})}}
      end
    end)
  end

  defp fake_compose(_args, {:fail, output}), do: {:ok, %{status: 1, output: output}}

  defp fake_compose(args, config) do
    if "config" in args do
      out = args |> Enum.drop_while(&(&1 != "-o")) |> Enum.at(1)
      File.write!(out, JSON.encode!(config))
    end

    {:ok, %{status: 0, output: ""}}
  end

  defp runs, do: receive_all([])

  defp receive_all(acc) do
    receive do
      {:run, c, a} -> receive_all([{c, a} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp logged do
    receive do
      {:log, _, data} -> data <> logged()
    after
      0 -> ""
    end
  end

  defp app_only, do: fn -> %{"services" => %{"app" => %{}}} end

  describe "the compose check" do
    test "sees every profile", %{ctx: ctx} do
      stub_tools(standard_layout(), app_only())
      assert {:ok, _} = Env.run("env.create", payload(), ctx)

      configs = for {"docker", ["compose" | args]} <- runs(), "config" in args, do: args
      assert length(configs) == 2

      for args <- configs do
        assert ["--profile", "*"] in Enum.chunk_every(args, 2, 1)
      end
    end

    # The CLI runs `compose up <runServices...> <service>`, and compose
    # starts a profiled service it's asked for by name.
    test "a privileged service behind a profile, named in runServices, is refused", %{ctx: ctx} do
      devcontainer = ~s({"dockerComposeFile": "docker-compose.yml", "service": "app",
                         "runServices": ["app", "debug"]})

      compose = fn ->
        %{
          "services" => %{
            "app" => %{},
            "debug" => %{"profiles" => ["debug"], "privileged" => true}
          }
        }
      end

      stub_tools(standard_layout(devcontainer), compose)

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "service 'debug' runs privileged"
      refute Enum.any?(runs(), &match?({"devcontainer", ["up" | _]}, &1))
    end

    test "refuses runServices that aren't in the compose files", %{ctx: ctx} do
      devcontainer = ~s({"dockerComposeFile": "docker-compose.yml", "service": "app",
                         "runServices": ["app", "ghost"]})

      stub_tools(standard_layout(devcontainer), app_only())

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "ghost"
    end

    # Compose's parse errors quote the file they choke on, which can be
    # any file the agent can read.
    test "a failing compose config goes to the log, not the error", %{ctx: ctx} do
      output =
        ~s(failed to read /var/lib/foreman-agent/identity.json: line 1: "{\\"private_key\\":\\"S3CR3T\\"}"\n)

      stub_tools(standard_layout(), fn -> {:fail, output} end)

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "docker compose config failed"
      refute message =~ "S3CR3T"
      assert logged() =~ "identity.json"
    end
  end

  describe "repo layouts" do
    test "a root-level .devcontainer.json", %{ctx: ctx, config: config} do
      layout = fn dest ->
        File.write!(
          Path.join(dest, ".devcontainer.json"),
          ~s({"dockerComposeFile": "docker-compose.yml", "service": "app"})
        )

        File.write!(Path.join(dest, "docker-compose.yml"), "services: {}\n")
      end

      stub_tools(layout, app_only())

      assert {:ok, _} =
               Env.run("env.create", payload(%{"config_path" => ".devcontainer.json"}), ctx)

      clone = Path.join([config.envs_root, @env_id, "workspace/storefront"])
      assert File.dir?(Path.join(clone, ".foreman/feature"))
      assert File.read!(Path.join(clone, ".git/info/exclude")) =~ ~r{^/\.foreman/$}m
    end

    test "a .devcontainer that links to a directory in the repo", %{ctx: ctx, config: config} do
      layout = fn dest ->
        standard_layout().(Path.join(dest, "tools"))
        File.ln_s!("tools/.devcontainer", Path.join(dest, ".devcontainer"))
      end

      stub_tools(layout, app_only())

      assert {:ok, _} = Env.run("env.create", payload(), ctx)

      clone = Path.join([config.envs_root, @env_id, "workspace/storefront"])
      assert File.dir?(Path.join(clone, "tools/.devcontainer/.foreman/feature"))
      assert File.read!(Path.join(clone, ".git/info/exclude")) =~ "/tools/.devcontainer/.foreman/"
    end
  end

  describe "retries" do
    # The developer pushes a fix and retries; the clone from the failed
    # attempt mustn't be checked again.
    test "a create that never came up clones again", %{ctx: ctx} do
      bad = %{
        "services" => %{
          "app" => %{"volumes" => [%{"type" => "bind", "source" => "/etc", "target" => "/e"}]}
        }
      }

      stub_tools(standard_layout(), fn -> bad end)
      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "/etc"
      assert Enum.any?(runs(), &match?({"git", _}, &1))

      stub_tools(standard_layout(), app_only())
      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      assert Enum.any?(runs(), &match?({"git", _}, &1))
    end

    test "once it has come up, the clone (and any work in it) is kept", %{
      ctx: ctx,
      config: config
    } do
      stub_tools(standard_layout(), app_only())
      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      _ = runs()

      work = Path.join([config.envs_root, @env_id, "workspace/storefront/work.txt"])
      File.write!(work, "unpushed")

      assert {:ok, _} = Env.run("env.create", payload(), ctx)
      assert {:ok, _} = Env.run("env.rebuild", payload(), ctx)
      refute Enum.any?(runs(), &match?({"git", _}, &1))
      assert File.read!(work) == "unpushed"
    end
  end

  describe "failures that used to crash" do
    test "a box without the devcontainer CLI gets an error", %{ctx: ctx} do
      stub_tools(standard_layout(), app_only(), devcontainer_missing: true)

      assert {:error, message} = Env.run("env.create", payload(), ctx)
      assert message =~ "devcontainer is not installed"
    end

    test "git status with no output is an error, not a crash", %{ctx: ctx} do
      stub_tools(standard_layout(), app_only())
      assert {:ok, _} = Env.run("env.create", payload(), ctx)

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

      stub(RunnerMock, :run, fn "docker", _args, _opts -> {:ok, %{status: 0, output: ""}} end)

      assert {:error, message} =
               Env.run("env.git_status", %{env_id: @env_id, slug: "storefront-2"}, ctx)

      assert message =~ "git status"
    end
  end
end
