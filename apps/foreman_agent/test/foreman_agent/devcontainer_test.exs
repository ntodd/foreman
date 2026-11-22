defmodule ForemanAgent.DevcontainerTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Devcontainer, DockerMock, RunnerMock}
  alias ForemanAgent.Test.FakeRegistry

  @moduletag :tmp_dir

  @fixture Path.expand("../fixtures/devcontainer/oracle/project/devcontainer", __DIR__)
  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @id_label "foreman.env_id=#{@env_id}"
  @container "5db0c73cc4bd175aae759bb61ff78e55b1cb167221d0ca8a2ec525702c30275a"

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "proj")
    File.mkdir_p!(workspace)
    File.cp_r!(@fixture, Path.join(workspace, ".devcontainer"))
    config_path = Path.join(workspace, ".devcontainer/devcontainer.json")
    {:ok, config} = ForemanProtocol.Jsonc.decode(File.read!(config_path))
    compose_file = Path.join(workspace, ".devcontainer/docker-compose.yml")
    test_pid = self()

    params = %{
      workspace: workspace,
      config_path: config_path,
      config: %{config | "dockerComposeFile" => [compose_file]},
      key_order: %{"containerEnv" => ["FROM_CONFIG", "ID"]},
      additional_features: %{},
      id_labels: [@id_label],
      remove_existing: false,
      lockfile: false,
      dotfiles: nil,
      env: %{
        "DOCKER_HOST" => "unix:///var/run/docker.sock",
        "COMPOSE_PROJECT_NAME" => "Storefront-2",
        "SECRET" => "s3cret"
      },
      state_dir: Path.join(tmp, "meta/devcontainer"),
      timeout: 60_000,
      uid: {1000, 1000},
      control: fn -> %{disallowed: [], advisories: []} end
    }

    ctx = %{
      config: %ForemanAgent.Config{docker_socket: "/var/run/docker.sock"},
      runner: RunnerMock,
      docker: DockerMock,
      log: fn stream, data -> send(test_pid, {:log, stream, data}) end
    }

    {:ok, world} =
      Agent.start_link(fn ->
        %{
          containers: %{},
          compose: %{
            "name" => "storefront-2",
            "services" => %{
              "app" => %{
                "build" => %{
                  "context" => Path.join(workspace, ".devcontainer"),
                  "dockerfile" => "Dockerfile"
                },
                "command" => ["sleep", "infinity"]
              },
              "db" => %{"image" => "postgres:17"}
            }
          },
          images: %{
            "debian:bookworm-slim" => %{
              "Config" => %{"User" => "", "Env" => ["PATH=/usr/bin"], "Labels" => nil},
              "Os" => "linux",
              "Architecture" => "arm64"
            },
            "storefront-2-app" => %{
              "Config" => %{"User" => "", "Entrypoint" => nil, "Cmd" => ["bash"], "Labels" => %{}},
              "Os" => "linux",
              "Architecture" => "arm64"
            }
          },
          fail: %{}
        }
      end)

    fake_docker(world)
    %{params: params, ctx: ctx, world: world, compose_file: compose_file}
  end

  # A Docker that keeps its containers in `world`.
  defp fake_docker(world) do
    test_pid = self()

    stub(DockerMock, :info, fn -> {:ok, %{"OSType" => "linux", "Architecture" => "aarch64"}} end)

    stub(DockerMock, :list_containers, fn labels ->
      wanted = Map.new(labels, &List.to_tuple(String.split(&1, "=", parts: 2)))

      {:ok,
       for {_, c} <- Agent.get(world, & &1.containers),
           Enum.all?(wanted, fn {k, v} -> c["Config"]["Labels"][k] == v end) do
         %{"Id" => c["Id"], "Labels" => c["Config"]["Labels"], "State" => c["State"]["Status"]}
       end}
    end)

    stub(DockerMock, :inspect_container, fn id ->
      case Agent.get(world, & &1.containers[id]) do
        nil -> {:error, {:http, 404, %{}}}
        container -> {:ok, container}
      end
    end)

    stub(DockerMock, :inspect_image, fn name ->
      case Agent.get(world, & &1.images[name]) do
        nil -> {:error, {:http, 404, %{}}}
        image -> {:ok, image}
      end
    end)

    stub(RunnerMock, :run, fn command, args, opts ->
      send(test_pid, {:run, command, args, opts})

      case Agent.get(world, & &1.fail[fail_key(command, args)]) do
        nil -> run(world, command, args, opts)
        {status, output} -> {:ok, %{status: status, output: output}}
      end
    end)
  end

  defp fail_key("docker", ["compose" | args]),
    do: {:compose, Enum.find(args, &(&1 in ["config", "build", "up"]))}

  defp fail_key("docker", [verb | _]), do: {:docker, verb}
  defp fail_key(command, _args), do: command

  defp run(world, "docker", ["compose" | args], _opts) do
    files = files(args)

    cond do
      "config" in args ->
        File.write!(List.last(args), JSON.encode!(Agent.get(world, & &1.compose)))

      "up" in args ->
        Agent.update(world, fn state ->
          container =
            state.containers[@container] ||
              %{
                "Id" => @container,
                "Created" => "2026-11-20T19:27:13.917532002Z",
                "Config" => %{
                  "User" => "",
                  "Env" => ["PATH=/usr/bin"],
                  "Labels" => %{
                    "com.docker.compose.project" => "storefront-2",
                    "com.docker.compose.service" => "app",
                    "com.docker.compose.project.config_files" => Enum.join(files, ","),
                    "foreman.env_id" => @env_id,
                    "devcontainer.metadata" =>
                      ~s([{"id":"./second","onCreateCommand":["echo","second-on-create"]},{"remoteUser":"dev"}])
                  }
                }
              }

          started = %{"Status" => "running", "StartedAt" => "2026-11-20T19:27:14.357527629Z"}
          put_in(state, [:containers, @container], Map.put(container, "State", started))
        end)

      true ->
        :ok
    end

    {:ok, %{status: 0, output: ""}}
  end

  defp run(world, "docker", ["rm", "-f", id], _opts) do
    Agent.update(world, &update_in(&1, [:containers], fn c -> Map.delete(c, id) end))
    {:ok, %{status: 0, output: ""}}
  end

  defp run(world, "docker", ["pull", image], _opts) do
    Agent.update(
      world,
      &put_in(&1, [:images, image], %{
        "Config" => %{"User" => "", "Labels" => %{}},
        "Os" => "linux",
        "Architecture" => "arm64"
      })
    )

    {:ok, %{status: 0, output: ""}}
  end

  defp run(world, "docker", ["build" | args], _opts) do
    tag = Enum.at(args, Enum.find_index(args, &(&1 == "-t")) + 1)
    Agent.update(world, &put_in(&1, [:images, tag], %{"Config" => %{"User" => ""}}))
    {:ok, %{status: 0, output: ""}}
  end

  # Whatever runs in the container works, and no hook has run yet.
  defp run(_world, _command, _args, _opts), do: {:ok, %{status: 0, output: ""}}

  defp files(args), do: for(["-f", file] <- Enum.chunk_every(args, 2, 1, :discard), do: file)

  defp runs(acc \\ []) do
    receive do
      {:run, command, args, opts} -> runs([{command, args, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp compose_runs(runs, verb) do
    for {"docker", ["compose" | args], opts} <- runs, verb in args, do: {args, opts}
  end

  defp stopped(world) do
    Agent.update(
      world,
      &put_in(&1, [:containers, @container, "State"], %{
        "Status" => "exited",
        "StartedAt" => "2026-11-20T19:27:14.357527629Z"
      })
    )
  end

  describe "up/2 for a new environment" do
    test "builds the image with the features, creates the container and sets it up", %{
      params: params,
      ctx: ctx,
      compose_file: compose_file
    } do
      assert {:ok, result} = Devcontainer.up(%{params | uid: nil}, ctx)

      assert result == %{
               container_id: @container,
               remote_user: "dev",
               remote_workspace_folder: "/workspaces/proj",
               compose_project: "storefront-2"
             }

      runs = runs()
      build_dir = Path.join(params.state_dir, "build")

      # The Dockerfile it builds is the service's own with the features on the end.
      dockerfile = File.read!(Path.join(build_dir, "Dockerfile-with-features"))

      assert dockerfile =~
               "FROM debian:bookworm-slim AS dev_container_auto_added_stage_label\nRUN useradd"

      assert dockerfile =~ "source=second_0,target=/tmp/build-features-src/second_0"
      assert dockerfile =~ "source=local-feature_1,target=/tmp/build-features-src/local-feature_1"

      assert File.read!(Path.join(build_dir, "devcontainer-features.builtin.env")) ==
               "_CONTAINER_USER=root\n_REMOTE_USER=dev\n"

      assert File.read!(Path.join(build_dir, "local-feature_1/devcontainer-features.env")) =~
               ~s(GREETING="hi there")

      assert [{build_args, build_opts}] = compose_runs(runs, "build")

      assert [
               "--project-name",
               "storefront-2",
               "-f",
               ^compose_file,
               "-f",
               build_file,
               "build",
               "app"
             ] = build_args

      assert Path.dirname(build_file) == Path.join(params.state_dir, "compose")
      assert Path.basename(build_file) =~ ~r/^docker-compose\.devcontainer\.build-\d+\.yml$/
      assert File.read!(build_file) =~ "dockerfile: #{build_dir}/Dockerfile-with-features\n"
      assert File.read!(build_file) =~ "- dev_containers_feature_content_source=#{build_dir}\n"
      assert build_opts[:env]["SECRET"] == "s3cret"

      assert [{up_args, _}] = compose_runs(runs, "up")

      assert [
               "--project-name",
               "storefront-2",
               "-f",
               ^compose_file,
               "-f",
               ^build_file,
               "-f",
               start_file,
               "up",
               "-d",
               "app"
             ] = up_args

      assert Path.basename(start_file) =~
               ~r/^docker-compose\.devcontainer\.containerFeatures-\d+-[0-9a-f-]{36}\.yml$/

      start = File.read!(start_file)
      assert start =~ "/usr/local/share/local-entry.sh\\n\n"
      assert start =~ "    init: true\n"
      assert start =~ "      - '#{@id_label}'\n"
      assert start =~ "      - 'FROM_CONFIG=a $$b \"c\"'\n"
      assert start =~ "      - oracle-data:/data\n"
      # The devcontainer's id is the id labels'.
      assert start =~
               "      - feature-vol-14hc2hhi4si9uhg5b17vg8229jse4p8fbbo5k69le7ui78mrrdj5:/feature-vol\n"

      refute start =~ "    image:"

      # Hooks ran as the remote user, in the workspace.
      assert Enum.any?(runs, fn {_, args, _} ->
               List.starts_with?(args, ["exec", "-i", "-u", "dev"]) and
                 Enum.take(args, -2) == ["echo", "second-on-create"]
             end)
    end

    test "gives the remote user the uid the agent runs as", %{params: params, ctx: ctx} do
      assert {:ok, _} = Devcontainer.up(params, ctx)

      runs = runs()
      assert {"docker", args, _} = Enum.find(runs, &match?({"docker", ["build" | _], _}, &1))

      name =
        "vsc-proj-" <>
          Base.encode16(:crypto.hash(:sha256, params.workspace), case: :lower) <> "-uid"

      assert [
               "build",
               "-f",
               dockerfile,
               "-t",
               ^name,
               "--platform",
               "linux/arm64",
               "--build-arg",
               "BASE_IMAGE=storefront-2-app",
               "--build-arg",
               "REMOTE_USER=dev",
               "--build-arg",
               "NEW_UID=1000",
               "--build-arg",
               "NEW_GID=1000",
               "--build-arg",
               "IMAGE_USER=root",
               empty
             ] = args

      assert File.read!(dockerfile) =~ "ARG BASE_IMAGE=placeholder\nFROM $BASE_IMAGE\n"
      assert File.ls!(empty) == []

      [{up_args, _}] = compose_runs(runs, "up")
      assert File.read!(Enum.at(up_args, 7)) =~ "    image: #{name}\n"
    end

    test "leaves the uid alone for root, when the config says to, and off Linux", %{
      params: params,
      ctx: ctx
    } do
      root = put_in(params, [:config, "remoteUser"], "root")
      assert {:ok, _} = Devcontainer.up(root, ctx)
      refute Enum.any?(runs(), &match?({"docker", ["build" | _], _}, &1))

      assert {:ok, _} =
               Devcontainer.up(
                 %{
                   put_in(params, [:config, "updateRemoteUserUID"], false)
                   | remove_existing: true
                 },
                 ctx
               )

      refute Enum.any?(runs(), &match?({"docker", ["build" | _], _}, &1))

      assert {:ok, _} = Devcontainer.up(%{params | uid: nil, remove_existing: true}, ctx)
      refute Enum.any?(runs(), &match?({"docker", ["build" | _], _}, &1))
    end

    test "runs the initialize command first, outside the containers", %{params: params, ctx: ctx} do
      params =
        put_in(params, [:config, "initializeCommand"], "touch ${localWorkspaceFolder}/ready")

      assert {:ok, _} = Devcontainer.up(params, ctx)

      runs = runs()
      index = Enum.find_index(runs, &match?({"/bin/sh", ["-c", _], _}, &1))
      assert {"/bin/sh", ["-c", command], opts} = Enum.at(runs, index)
      assert command == "touch #{params.workspace}/ready"
      assert opts[:cd] == params.workspace
      assert index < Enum.find_index(runs, &match?({"docker", ["compose" | _], _}, &1))
    end

    test "a service that only names an image gets one built from it", %{
      params: params,
      ctx: ctx,
      world: world
    } do
      Agent.update(
        world,
        &put_in(&1, [:compose, "services", "app"], %{"image" => "debian:bookworm-slim"})
      )

      name = "vsc-proj-" <> Base.encode16(:crypto.hash(:sha256, params.workspace), case: :lower)

      Agent.update(
        world,
        &put_in(&1, [:images, name], %{"Config" => %{"User" => "", "Cmd" => ["bash"]}})
      )

      assert {:ok, _} = Devcontainer.up(%{params | uid: nil}, ctx)

      runs = runs()
      [{build_args, _}] = compose_runs(runs, "build")
      build_file = Enum.at(build_args, 5)
      assert File.read!(build_file) =~ "    image: #{name}\n    build:\n"
      assert File.read!(build_file) =~ "      context: #{Path.join(params.state_dir, "empty")}\n"

      assert File.read!(Path.join(params.state_dir, "build/Dockerfile-with-features")) =~
               "FROM debian:bookworm-slim AS dev_container_auto_added_stage_label\n"

      [{up_args, _}] = compose_runs(runs, "up")
      assert File.read!(Enum.at(up_args, 7)) =~ ~s(    command: ["bash"]\n)
    end

    test "pulls a base image the box doesn't have, to read what it says", %{
      params: params,
      ctx: ctx,
      world: world
    } do
      Agent.update(
        world,
        &update_in(&1, [:images], fn images -> Map.delete(images, "debian:bookworm-slim") end)
      )

      assert {:ok, _} = Devcontainer.up(params, ctx)
      assert Enum.any?(runs(), &match?({"docker", ["pull", "debian:bookworm-slim"], _}, &1))
    end

    # hostRequirements.gpu would otherwise reserve GPUs after the box's
    # policy has checked the compose files.
    test "never reserves a GPU, whatever the config or an image asks for", %{
      params: params,
      ctx: ctx
    } do
      params = put_in(params, [:config, "hostRequirements"], %{"gpu" => true})

      assert {:ok, _} = Devcontainer.up(%{params | uid: nil}, ctx)

      [{up_args, _}] = compose_runs(runs(), "up")
      start = File.read!(Enum.at(up_args, 7))
      refute start =~ "deploy"
      refute start =~ "gpu"
    end

    test "starts the services the config lists, and the devcontainer's", %{
      params: params,
      ctx: ctx
    } do
      assert {:ok, _} = Devcontainer.up(put_in(params, [:config, "runServices"], ["db"]), ctx)

      runs = runs()
      assert [{build_args, _}] = compose_runs(runs, "build")
      assert Enum.take(build_args, -3) == ["build", "db", "app"]
      assert [{up_args, _}] = compose_runs(runs, "up")
      assert Enum.take(up_args, -4) == ["up", "-d", "db", "app"]
    end

    test "keeps a .devcontainer that's a link into the repo when it writes the lock file", %{
      params: params,
      ctx: ctx
    } do
      real = Path.join(params.workspace, "tools/.devcontainer")
      File.mkdir_p!(Path.dirname(real))
      File.rename!(Path.join(params.workspace, ".devcontainer"), real)
      File.ln_s!("tools/.devcontainer", Path.join(params.workspace, ".devcontainer"))

      params = %{
        params
        | lockfile: true,
          config: %{
            params.config
            | "dockerComposeFile" => [Path.join(real, "docker-compose.yml")]
          }
      }

      assert {:ok, _} = Devcontainer.up(params, ctx)

      assert File.read_link(Path.join(params.workspace, ".devcontainer")) ==
               {:ok, "tools/.devcontainer"}

      assert File.read!(Path.join(real, "devcontainer-lock.json")) == "{\n  \"features\": {}\n}\n"
      assert File.exists?(Path.join(params.workspace, ".devcontainer/devcontainer.json"))
    end

    test "refuses malformed feature pins before building", %{params: params, ctx: ctx} do
      path = Path.join(params.workspace, ".devcontainer/devcontainer-lock.json")

      for features <- [[], %{"ghcr.io/o/f:1" => "bad"}] do
        contents = JSON.encode!(%{"features" => features})
        File.write!(path, contents)
        assert {:error, reason} = Devcontainer.up(%{params | lockfile: true}, ctx)
        assert reason =~ "fix or delete it"
        assert File.read!(path) == contents
      end
    end

    test "starts a lock file that's there but empty", %{params: params, ctx: ctx} do
      path = Path.join(params.workspace, ".devcontainer/devcontainer-lock.json")
      File.write!(path, "\n")

      assert {:ok, _} = Devcontainer.up(%{params | lockfile: true}, ctx)
      assert File.read!(path) == "{\n  \"features\": {}\n}\n"
    end

    test "refuses a lock file it can't read, and leaves it as it is", %{params: params, ctx: ctx} do
      path = Path.join(params.workspace, ".devcontainer/devcontainer-lock.json")
      File.write!(path, "<<<<<<< HEAD\n{\n")

      assert Devcontainer.up(%{params | lockfile: true}, ctx) ==
               {:error, ".devcontainer/devcontainer-lock.json isn't valid JSON; fix or delete it"}

      assert File.read!(path) == "<<<<<<< HEAD\n{\n"
      assert compose_runs(runs(), "build") == []
    end

    test "runs an initialize command given as a path in the repo", %{params: params, ctx: ctx} do
      params =
        put_in(params, [:config, "initializeCommand"], ["./scripts/bootstrap.sh", "--fast"])

      assert {:ok, _} = Devcontainer.up(params, ctx)

      bootstrap = Path.join(params.workspace, "scripts/bootstrap.sh")
      assert {^bootstrap, ["--fast"], opts} = Enum.find(runs(), &match?({_, ["--fast"], _}, &1))
      assert opts[:cd] == params.workspace
    end

    # The initialize command can change what compose resolves (a .env it
    # writes, say), so the project is read after it has run.
    test "reads the compose project after the initialize command, into the scratch folder", %{
      params: params,
      ctx: ctx,
      tmp_dir: tmp
    } do
      scratch = Path.join(tmp, "tmpfs")
      File.mkdir_p!(scratch)

      params =
        params |> put_in([:config, "initializeCommand"], "true") |> Map.put(:scratch_dir, scratch)

      assert {:ok, _} = Devcontainer.up(params, ctx)

      runs = runs()
      [{config_args, _}] = compose_runs(runs, "config")
      out = List.last(config_args)
      assert Path.dirname(out) == scratch
      assert Path.basename(out) =~ ~r/^\.docker-compose-[A-Za-z0-9_-]+\.json$/
      refute File.exists?(out)
      assert File.ls!(scratch) == []

      initialized = Enum.find_index(runs, &match?({"/bin/sh", ["-c", "true"], _}, &1))
      configured = Enum.find_index(runs, &match?({"docker", ["compose" | _], _}, &1))
      assert initialized < configured
    end

    test "skips the empty ones among an initialize command's named commands", %{
      params: params,
      ctx: ctx
    } do
      params =
        put_in(params, [:config, "initializeCommand"], %{
          "nothing" => [],
          "blank" => "  ",
          "real" => "echo hi"
        })

      assert {:ok, _} = Devcontainer.up(params, ctx)

      assert [{"/bin/sh", ["-c", "echo hi"], _}] =
               Enum.filter(runs(), &match?({"/bin/sh", _, _}, &1))
    end

    test "writes through a lock file that's a link to one elsewhere in the repo", %{
      params: params,
      ctx: ctx
    } do
      shared = Path.join(params.workspace, "shared/lock.json")
      File.mkdir_p!(Path.dirname(shared))
      File.write!(shared, "{}")
      link = Path.join(params.workspace, ".devcontainer/devcontainer-lock.json")
      File.ln_s!("../shared/lock.json", link)

      assert {:ok, _} = Devcontainer.up(%{params | lockfile: true}, ctx)

      assert File.read_link(link) == {:ok, "../shared/lock.json"}
      assert File.read!(shared) == "{\n  \"features\": {}\n}\n"
    end

    test "won't follow a lock file's link out of the repo", %{
      params: params,
      ctx: ctx,
      tmp_dir: tmp
    } do
      outside = Path.join(tmp, "outside-lock.json")
      File.write!(outside, "{}")
      File.ln_s!(outside, Path.join(params.workspace, ".devcontainer/devcontainer-lock.json"))

      assert {:error, "couldn't read .devcontainer/devcontainer-lock.json: " <> _} =
               Devcontainer.up(%{params | lockfile: true}, ctx)

      assert File.read!(outside) == "{}"
    end

    test "refuses a lock file that's a link to nothing", %{params: params, ctx: ctx} do
      link = Path.join(params.workspace, ".devcontainer/devcontainer-lock.json")
      File.ln_s!("../shared/gone.json", link)

      assert Devcontainer.up(%{params | lockfile: true}, ctx) ==
               {:error, ".devcontainer/devcontainer-lock.json is a link that leads nowhere"}

      assert File.read_link(link) == {:ok, "../shared/gone.json"}
    end

    test "reads the compose file's version only from a file in the repo", %{
      params: params,
      ctx: ctx,
      compose_file: compose_file,
      tmp_dir: tmp
    } do
      File.write!(compose_file, "version: '3.8'\nservices: {}\n")
      assert {:ok, _} = Devcontainer.up(%{params | uid: nil}, ctx)
      [{up_args, _}] = compose_runs(runs(), "up")
      assert String.starts_with?(File.read!(Enum.at(up_args, 7)), "version: '3.8'\n\nservices:")

      outside = Path.join(tmp, "outside.yml")
      File.write!(outside, "version: 'from-outside'\n")
      File.rm!(compose_file)
      File.ln_s!(outside, compose_file)

      assert {:ok, _} = Devcontainer.up(%{params | uid: nil, remove_existing: true}, ctx)
      [{up_args, _}] = compose_runs(runs(), "up")
      assert String.starts_with?(File.read!(Enum.at(up_args, 7)), "services:")
    end

    test "writes the lock file when asked, next to the config", %{params: params, ctx: ctx} do
      assert {:ok, _} = Devcontainer.up(%{params | lockfile: true}, ctx)

      assert File.read!(Path.join(params.workspace, ".devcontainer/devcontainer-lock.json")) ==
               "{\n  \"features\": {}\n}\n"
    end
  end

  describe "up/2 for an environment that exists" do
    test "sets up a running container without building or starting anything", %{
      params: params,
      ctx: ctx
    } do
      assert {:ok, _} = Devcontainer.up(params, ctx)
      runs()

      assert {:ok, %{container_id: @container, remote_user: "dev"}} = Devcontainer.up(params, ctx)

      runs = runs()
      assert compose_runs(runs, "build") == []
      assert compose_runs(runs, "up") == []
    end

    test "starts a stopped container with the files it was created with", %{
      params: params,
      ctx: ctx,
      world: world,
      compose_file: compose_file
    } do
      assert {:ok, _} = Devcontainer.up(params, ctx)
      [{first_up, _}] = compose_runs(runs(), "up")
      stopped(world)

      assert {:ok, _} = Devcontainer.up(params, ctx)

      runs = runs()
      assert compose_runs(runs, "build") == []
      assert [{up_args, _}] = compose_runs(runs, "up")

      [build_file, start_file] = first_up |> files() |> tl()

      assert up_args == [
               "--project-name",
               "storefront-2",
               "-f",
               compose_file,
               "-f",
               build_file,
               "-f",
               start_file,
               "up",
               "-d",
               "--no-recreate",
               "app"
             ]
    end

    test "writes the files again, without building, when they're gone", %{
      params: params,
      ctx: ctx,
      world: world
    } do
      assert {:ok, _} = Devcontainer.up(params, ctx)
      runs()
      stopped(world)
      File.rm_rf!(Path.join(params.state_dir, "compose"))

      assert {:ok, _} = Devcontainer.up(params, ctx)

      runs = runs()
      assert compose_runs(runs, "build") == []
      refute Enum.any?(runs, &match?({"docker", ["build" | _], _}, &1))
      assert [{up_args, _}] = compose_runs(runs, "up")
      assert "--no-recreate" in up_args
      assert [_, build_file, start_file] = files(up_args)
      assert File.exists?(build_file) and File.exists?(start_file)
    end

    # A container compose made on its own, or one whose label was written
    # before the devcontainer had override files.
    test "starts a stopped container that was never given override files", %{
      params: params,
      ctx: ctx,
      world: world,
      compose_file: compose_file
    } do
      assert {:ok, _} = Devcontainer.up(params, ctx)
      runs()
      stopped(world)

      Agent.update(
        world,
        &put_in(
          &1,
          [
            :containers,
            @container,
            "Config",
            "Labels",
            "com.docker.compose.project.config_files"
          ],
          compose_file
        )
      )

      assert {:ok, %{container_id: @container}} = Devcontainer.up(params, ctx)

      runs = runs()
      assert compose_runs(runs, "build") == []
      assert [{up_args, _}] = compose_runs(runs, "up")
      assert "--no-recreate" in up_args
      assert [_, _build_file, _start_file] = files(up_args)
    end

    test "removes the container first for a rebuild", %{params: params, ctx: ctx} do
      assert {:ok, _} = Devcontainer.up(params, ctx)
      [{first_up, _}] = compose_runs(runs(), "up")

      assert {:ok, _} = Devcontainer.up(%{params | remove_existing: true}, ctx)

      runs = runs()
      assert Enum.any?(runs, &match?({"docker", ["rm", "-f", @container], _}, &1))
      assert [_] = compose_runs(runs, "build")
      assert [{up_args, _}] = compose_runs(runs, "up")
      refute "--no-recreate" in up_args

      # The last build's files went with it.
      for file <- first_up |> files() |> tl(), do: refute(File.exists?(file))
    end
  end

  describe "up/2 when something goes wrong" do
    test "a build that fails", %{params: params, ctx: ctx, world: world} do
      Agent.update(
        world,
        &put_in(&1, [:fail, {:compose, "build"}], {1, "step 3\nERROR: failed to solve: boom\n"})
      )

      assert Devcontainer.up(params, ctx) ==
               {:error,
                "building the devcontainer's image failed: step 3\nERROR: failed to solve: boom"}
    end

    test "containers that won't start", %{params: params, ctx: ctx, world: world} do
      Agent.update(
        world,
        &put_in(&1, [:fail, {:compose, "up"}], {1, "Error response from daemon: no\n"})
      )

      assert Devcontainer.up(params, ctx) ==
               {:error, "starting the containers failed: Error response from daemon: no"}
    end

    test "an initialize command that fails", %{params: params, ctx: ctx, world: world} do
      Agent.update(world, &put_in(&1, [:fail, "/bin/sh"], {2, "nope\n"}))

      assert Devcontainer.up(put_in(params, [:config, "initializeCommand"], "false"), ctx) ==
               {:error, "the initializeCommand in the devcontainer.json failed with exit code 2"}

      assert compose_runs(runs(), "build") == []
    end

    test "a service the compose files don't have", %{params: params, ctx: ctx} do
      assert Devcontainer.up(put_in(params, [:config, "service"], "web"), ctx) ==
               {:error, "the service 'web' in the devcontainer.json isn't in the compose files"}
    end

    test "a Dockerfile outside the repository", %{params: params, ctx: ctx, world: world} do
      Agent.update(
        world,
        &put_in(&1, [:compose, "services", "app", "build"], %{
          "context" => "/etc",
          "dockerfile" => "passwd"
        })
      )

      assert Devcontainer.up(params, ctx) ==
               {:error, "the Dockerfile of the service 'app' has to be in the repository"}
    end

    test "a Dockerfile with nothing to build on", %{params: params, ctx: ctx} do
      File.write!(Path.join(params.workspace, ".devcontainer/Dockerfile"), "# nothing yet\n")

      assert Devcontainer.up(params, ctx) ==
               {:error,
                "the Dockerfile of the service 'app' can't be built on: the Dockerfile has no FROM instruction"}
    end

    test "a feature that's been pulled for being harmful", %{
      params: params,
      ctx: ctx,
      world: world
    } do
      assert {:ok, _} = Devcontainer.up(params, ctx)
      runs()

      # A sidecar of the same environment, with the same id label.
      Agent.update(world, fn state ->
        put_in(state, [:containers, "db1"], %{
          "Id" => "db1",
          "State" => %{"Status" => "running"},
          "Config" => %{
            "Labels" => %{
              "com.docker.compose.project" => "storefront-2",
              "com.docker.compose.service" => "db",
              "foreman.env_id" => @env_id
            }
          }
        })
      end)

      control = fn ->
        %{
          disallowed: [
            %{"featureIdPrefix" => "./second", "documentationURL" => "https://example.com/why"}
          ],
          advisories: []
        }
      end

      assert Devcontainer.up(%{params | control: control}, ctx) ==
               {:error,
                "the feature ./second was reported as harmful and can't be used. Remove it from the devcontainer.json " <>
                  "and rebuild. The devcontainer was stopped. See https://example.com/why"}

      runs = runs()
      # Only the devcontainer: the database beside it gets to shut down properly.
      assert [["stop", "-t", "0", @container]] =
               for({"docker", ["stop" | _] = args, _} <- runs, do: args)

      assert compose_runs(runs, "config") == []
    end

    test "a feature that can't be found", %{params: params, ctx: ctx} do
      assert {:error, "the feature fish isn't one Foreman can find" <> _} =
               Devcontainer.up(put_in(params, [:config, "features"], %{"fish" => %{}}), ctx)
    end

    test "a box without docker", %{params: params, ctx: ctx} do
      stub(RunnerMock, :run, fn "docker", _args, _opts -> {:error, {:not_found, "docker"}} end)

      assert Devcontainer.up(params, ctx) == {:error, "docker is not installed on this box"}
    end

    test "features that take too long to get are cut off at the deadline", %{
      params: params,
      ctx: ctx
    } do
      registry = FakeRegistry.start(delay: 3_000)

      FakeRegistry.put_feature(registry, "org/features/slow", "1", %{
        "id" => "slow"
      })

      params =
        put_in(params, [:config, "features"], %{"#{registry.host}/org/features/slow:1" => %{}})

      started = System.monotonic_time(:millisecond)

      assert {:error, message} = Devcontainer.up(%{params | timeout: 400}, ctx)
      assert message =~ "devcontainer up timed out"
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert compose_runs(runs(), "build") == []
    end

    test "running out of time", %{params: params, ctx: ctx} do
      assert {:error, message} = Devcontainer.up(%{params | timeout: 0}, ctx)
      assert message =~ "timed out"
    end

    test "never logs the compose config, which has secrets in it", %{
      params: params,
      ctx: ctx,
      world: world
    } do
      Agent.update(
        world,
        &put_in(&1, [:compose, "services", "db", "environment"], %{"PASSWORD" => "hunter2"})
      )

      assert {:ok, _} = Devcontainer.up(params, ctx)

      refute Enum.any?(log(), &(&1 =~ "hunter2"))
      refute File.exists?(Path.join(params.state_dir, "compose-config.json"))
    end
  end

  defp log(acc \\ []) do
    receive do
      {:log, _, text} -> log([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
