defmodule ForemanAgent.Devcontainer.LifecycleTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.Devcontainer.Lifecycle
  alias ForemanAgent.RunnerMock

  setup :verify_on_exit!

  @container_id "5db0c73cc4bd175aae759bb61ff78e55b1cb167221d0ca8a2ec525702c30275a"
  @created "2026-11-20T19:27:13.917532002Z"
  @started "2026-11-20T19:27:14.357527629Z"

  @container %{
    "Id" => @container_id,
    "Created" => @created,
    "State" => %{"StartedAt" => @started, "Status" => "running"},
    "Config" => %{
      "User" => "root",
      "Env" => ["PATH=/usr/local/bin:/usr/bin:/bin", "FROM_CONFIG=a b"]
    }
  }

  setup do
    test_pid = self()

    ctx = %{
      config: %ForemanAgent.Config{docker_socket: "/var/run/docker.sock"},
      runner: RunnerMock,
      log: fn stream, data -> send(test_pid, {:log, stream, data}) end
    }

    %{ctx: ctx}
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        container: @container,
        merged: %{
          "remoteUser" => "dev",
          "remoteEnv" => %{"REMOTE_ONE" => "one", "WITH_PATH" => "${containerEnv:PATH}:/extra"},
          "userEnvProbe" => nil
        },
        origins: %{
          "onCreateCommand" => [{"./second", ["echo", "second-on-create"]}],
          "updateContentCommand" => [],
          "postCreateCommand" => [
            {"./local-feature", "echo feature-post-create"},
            {"devcontainer.json", "echo post-create"}
          ],
          "postStartCommand" => [{"devcontainer.json", "echo started"}],
          "postAttachCommand" => [{"devcontainer.json", "echo attached"}]
        },
        remote_workspace_folder: "/workspaces/proj",
        dotfiles: nil,
        env: %{"DOCKER_HOST" => "unix:///var/run/docker.sock"},
        deadline: System.monotonic_time(:millisecond) + 60_000
      },
      overrides
    )
  end

  # A container: answers `docker exec` by what's run in it. `answers` maps
  # a predicate on {user, env, cwd, command} to {status, output}; the
  # default is how a fresh debian container with a `dev` user answers.
  defp container(answers \\ []) do
    test_pid = self()
    {:ok, files} = Agent.start_link(fn -> MapSet.new() end)

    stub(RunnerMock, :run, fn "docker", ["exec", "-i" | rest], opts ->
      exec = parse_exec(rest)
      send(test_pid, {:exec, exec})

      {status, output} =
        Enum.find_value(answers, fn answer -> answer.(exec) end) || default(exec, files)

      if output != "", do: opts[:on_output].(output)
      {:ok, %{status: status, output: output}}
    end)

    files
  end

  defp parse_exec(args, acc \\ %{user: nil, env: %{}, cwd: nil})

  defp parse_exec(["-u", user | rest], acc), do: parse_exec(rest, %{acc | user: user})
  defp parse_exec(["-w", cwd | rest], acc), do: parse_exec(rest, %{acc | cwd: cwd})

  defp parse_exec(["-e", pair | rest], acc) do
    [name, value] = String.split(pair, "=", parts: 2)
    parse_exec(rest, %{acc | env: Map.put(acc.env, name, value)})
  end

  defp parse_exec([@container_id | command], acc), do: Map.put(acc, :command, command)

  defp default(%{command: ["/bin/sh", "-c", script]}, files) do
    cond do
      script =~ "getent passwd 'dev'" -> {0, "dev:x:1000:1000::/home/dev:/bin/bash\n"}
      script =~ "getent passwd 'root'" -> {0, "root:x:0:0:root:/root:/bin/bash\n"}
      String.starts_with?(script, "test -f ") -> {status(seen?(files, script, false)), ""}
      String.starts_with?(script, "test ! -f ") -> create_file(files, script)
      script =~ "CONTENT=" -> marker(files, script)
      true -> {0, ""}
    end
  end

  defp default(%{command: [shell, "-lic", probe]}, _files)
       when shell in ["/bin/bash", "/bin/sh"] do
    [_, mark] = Regex.run(~r/^echo -n (\S+);/, probe)
    env = "HOME=/home/dev\0PATH=/home/dev/bin:/usr/bin\0PWD=/\0SHELL_VAR=from-profile\0"
    {0, "bash: no job control in this shell\n" <> mark <> env <> mark}
  end

  defp default(_exec, _files), do: {0, ""}

  defp status(true), do: 0
  defp status(false), do: 1

  # Whether `key` has been seen, remembering it from now on if asked to.
  defp seen?(files, key, remember?) do
    Agent.get_and_update(files, fn seen ->
      {MapSet.member?(seen, key), if(remember?, do: MapSet.put(seen, key), else: seen)}
    end)
  end

  # createFile: fails when the file is already there.
  defp create_file(files, script) do
    [_, path] = Regex.run(~r/^test ! -f '([^']+)'/, script)
    {status(not seen?(files, "test -f '#{path}'", true)), ""}
  end

  # A lifecycle marker: succeeds the first time it sees its content.
  defp marker(files, script) do
    [_, content, marker] =
      Regex.run(
        ~r/echo '([^']+)' > '[^']+\.tmp' && mv -f '[^']+\.tmp' '([^']+)' \|\| exit 21$/,
        script
      )

    {if(seen?(files, {marker, content}, true), do: 20, else: 0), ""}
  end

  defp execs(acc \\ []) do
    receive do
      {:exec, exec} -> execs([exec | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp logged(acc \\ []) do
    receive do
      {:log, "info", text} -> logged([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  # The commands a person wrote, without the bookkeeping around them.
  defp user_commands(execs) do
    for %{command: command, cwd: "/workspaces/proj"} = exec <- execs, do: {exec.user, command}
  end

  describe "run/2 in a new container" do
    test "runs each hook's commands in order, as the remote user, in the workspace", %{ctx: ctx} do
      container()

      assert {:ok, result} = Lifecycle.run(params(), ctx)
      assert result.remote_user == "dev"

      assert user_commands(execs()) == [
               {"dev", ["echo", "second-on-create"]},
               {"dev", ["/bin/sh", "-c", "echo feature-post-create"]},
               {"dev", ["/bin/sh", "-c", "echo post-create"]},
               {"dev", ["/bin/sh", "-c", "echo started"]}
             ]
    end

    test "gives the commands the user's shell environment, then the config's", %{ctx: ctx} do
      container()

      assert {:ok, result} = Lifecycle.run(params(), ctx)

      expected = %{
        "HOME" => "/home/dev",
        "PATH" => "/home/dev/bin:/usr/bin",
        "SHELL_VAR" => "from-profile",
        "REMOTE_ONE" => "one",
        "WITH_PATH" => "/usr/local/bin:/usr/bin:/bin:/extra"
      }

      assert result.remote_env == expected

      assert %{env: ^expected} =
               Enum.find(execs(), &(&1.command == ["/bin/sh", "-c", "echo post-create"]))
    end

    test "asks the user's login shell for its environment", %{ctx: ctx} do
      container()

      assert {:ok, _} = Lifecycle.run(params(), ctx)

      assert %{user: "dev", cwd: nil, command: ["/bin/bash", "-lic", probe]} =
               Enum.find(execs(), &match?(%{command: [_, "-lic", _]}, &1))

      assert probe =~ ~r/^echo -n (\S+); cat \/proc\/self\/environ; echo -n \1$/
    end

    test "probes with the shell and flags the config asks for, or not at all", %{ctx: ctx} do
      container()

      assert {:ok, _} =
               Lifecycle.run(
                 params(%{merged: %{"remoteUser" => "dev", "userEnvProbe" => "loginShell"}}),
                 ctx
               )

      assert Enum.any?(execs(), &match?(%{command: ["/bin/bash", "-lc", _]}, &1))

      assert {:ok, result} =
               Lifecycle.run(
                 params(%{
                   merged: %{
                     "remoteUser" => "dev",
                     "userEnvProbe" => "none",
                     "remoteEnv" => %{"A" => "1", "GONE" => nil}
                   }
                 }),
                 ctx
               )

      refute Enum.any?(
               execs(),
               &match?(%{command: [_, flag, _]} when flag in ["-lic", "-lc", "-ic"], &1)
             )

      assert result.remote_env == %{"A" => "1"}
    end

    test "carries on without an environment the shell wouldn't give", %{ctx: ctx} do
      container([fn exec -> if match?(%{command: [_, "-lic", _]}, exec), do: {1, "boom"} end])

      assert {:ok, result} = Lifecycle.run(params(), ctx)

      assert result.remote_env == %{
               "REMOTE_ONE" => "one",
               "WITH_PATH" => "/usr/local/bin:/usr/bin:/bin:/extra"
             }
    end

    test "writes the container's environment to /etc/environment, and fixes /etc/profile's PATH, once",
         %{ctx: ctx} do
      container()

      assert {:ok, _} = Lifecycle.run(params(), ctx)
      first = execs()

      assert %{user: "root", command: ["/bin/sh", "-c", script]} =
               Enum.find(first, &match?(%{command: [_, _, "cat >> /etc/environment" <> _]}, &1))

      assert script ==
               "cat >> /etc/environment <<'etcEnvironmentEOF'\n\nPATH=\"/usr/local/bin:/usr/bin:/bin\"\nFROM_CONFIG=\"a b\"\netcEnvironmentEOF\n"

      assert Enum.any?(first, fn exec ->
               exec.user == "root" and
                 exec.command == [
                   "/bin/sh",
                   "-c",
                   ~S"sed -i -E 's/((^|\s)PATH=)([^\$]*)$/\1${PATH:-\3}/g' /etc/profile || true"
                 ]
             end)

      assert {:ok, _} = Lifecycle.run(params(), ctx)
      refute Enum.any?(execs(), &match?(%{command: [_, _, "cat >> /etc/environment" <> _]}, &1))
    end

    test "says what's running, and logs what the commands print", %{ctx: ctx} do
      container([
        fn exec ->
          if exec.command == ["/bin/sh", "-c", "echo post-create"], do: {0, "post-create\n"}
        end
      ])

      assert {:ok, _} = Lifecycle.run(params(), ctx)

      log = logged()
      assert log =~ "Running the onCreateCommand from Feature './second'...\n"
      assert log =~ "Running the postCreateCommand from devcontainer.json...\n"
      assert log =~ "post-create\n"
      refute log =~ "getent"
    end
  end

  describe "run/2 in a container that's been set up" do
    test "runs only the start hook when the container starts again", %{ctx: ctx} do
      container()
      assert {:ok, _} = Lifecycle.run(params(), ctx)
      execs()

      restarted = put_in(@container, ["State", "StartedAt"], "2026-11-21T08:00:00.000000000Z")
      assert {:ok, _} = Lifecycle.run(params(%{container: restarted}), ctx)
      assert user_commands(execs()) == [{"dev", ["/bin/sh", "-c", "echo started"]}]

      assert {:ok, _} = Lifecycle.run(params(%{container: restarted}), ctx)
      assert user_commands(execs()) == []
    end
  end

  describe "hooks" do
    test "a command that fails stops the rest", %{ctx: ctx} do
      container([
        fn exec ->
          if exec.command == ["/bin/sh", "-c", "echo feature-post-create"], do: {3, "nope\n"}
        end
      ])

      assert Lifecycle.run(params(), ctx) ==
               {:error,
                "postCreateCommand from Feature './local-feature' failed with exit code 3"}

      refute {"dev", ["/bin/sh", "-c", "echo post-create"]} in user_commands(execs())
      assert logged() =~ "nope\n"
    end

    test "an object's commands run side by side, each printed whole when it's done", %{ctx: ctx} do
      container([
        fn exec ->
          case exec.command do
            ["/bin/sh", "-c", "echo start-a"] -> {0, "start-a\n"}
            ["echo", "start-b"] -> {0, "start-b\n"}
            _ -> nil
          end
        end
      ])

      origins =
        put_in(params().origins, ["postStartCommand"], [
          {"devcontainer.json", %{"a" => "echo start-a", "b" => ["echo", "start-b"]}}
        ])

      assert {:ok, _} = Lifecycle.run(params(%{origins: origins}), ctx)

      commands = user_commands(execs())
      assert {"dev", ["/bin/sh", "-c", "echo start-a"]} in commands
      assert {"dev", ["echo", "start-b"]} in commands

      log = logged()
      assert log =~ "Running a of postStartCommand from devcontainer.json...\nstart-a\n"
      assert log =~ "Running b of postStartCommand from devcontainer.json...\nstart-b\n"
    end

    test "one of an object's commands failing fails the hook, after the others finish", %{
      ctx: ctx
    } do
      container([fn exec -> if exec.command == ["/bin/sh", "-c", "exit 4"], do: {4, ""} end])

      origins =
        put_in(params().origins, ["postStartCommand"], [
          {"devcontainer.json", %{"bad" => "exit 4", "good" => "echo ok"}}
        ])

      assert Lifecycle.run(params(%{origins: origins}), ctx) ==
               {:error, "bad of postStartCommand from devcontainer.json failed with exit code 4"}

      assert {"dev", ["/bin/sh", "-c", "echo ok"]} in user_commands(execs())
    end

    test "commands with nothing in them are skipped", %{ctx: ctx} do
      container()

      origins =
        Map.merge(params().origins, %{
          "onCreateCommand" => [
            {"devcontainer.json", "   "},
            {"devcontainer.json", []},
            {"devcontainer.json", %{}}
          ],
          "postCreateCommand" => [],
          "postStartCommand" => []
        })

      assert {:ok, _} = Lifecycle.run(params(%{origins: origins}), ctx)
      assert user_commands(execs()) == []
    end

    test "the attach hook runs when it isn't skipped", %{ctx: ctx} do
      container()

      assert {:ok, _} = Lifecycle.run(params(%{skip_post_attach: false}), ctx)
      assert List.last(user_commands(execs())) == {"dev", ["/bin/sh", "-c", "echo attached"]}
    end
  end

  describe "the user" do
    test "is the container's own when the config names none", %{ctx: ctx} do
      container()
      as_user = put_in(@container, ["Config", "User"], "0:0")

      assert {:ok, %{remote_user: "root"}} =
               Lifecycle.run(params(%{container: as_user, merged: %{}}), ctx)

      assert Enum.all?(execs(), &(&1.user in ["0:0", "root"]))
    end

    test "falls back to /bin/sh, and to a home it can write to, when passwd doesn't know the user",
         %{ctx: ctx} do
      container([
        fn exec ->
          if match?(%{command: [_, _, " (command -v getent" <> _]}, exec), do: {0, ""}
        end
      ])

      with_home = update_in(@container, ["Config", "Env"], &["HOME=/custom" | &1])

      assert {:ok, _} = Lifecycle.run(params(%{container: with_home}), ctx)

      all = execs()
      assert Enum.any?(all, &match?(%{command: ["/bin/sh", "-lic", _]}, &1))

      assert Enum.any?(
               all,
               &(&1.command == ["/bin/sh", "-c", "[ ! -e '/custom' ] || [ -w '/custom' ]"])
             )

      assert Enum.any?(
               all,
               &match?(%{command: [_, _, "mkdir -p '/custom/.devcontainer' " <> _]}, &1)
             )
    end
  end

  describe "a container commands can't run in" do
    # Docker refuses every exec as a user the image doesn't have.
    test "is an error, not an environment with nothing set up", %{ctx: ctx} do
      container([
        fn exec ->
          if exec.user == "dev",
            do: {126, "unable to find user dev: no matching entries in passwd file\n"}
        end
      ])

      assert Lifecycle.run(params(), ctx) ==
               {:error,
                "couldn't run commands in the devcontainer as dev: unable to find user dev: no matching entries in passwd file"}

      assert user_commands(execs()) == []
    end

    # The remote user can't write where the markers go (a read-only home).
    test "a hook that has commands and can't keep its marker is an error", %{ctx: ctx} do
      container([
        fn exec ->
          if match?(%{command: [_, _, "mkdir -p " <> _]}, exec),
            do:
              {21,
               "mkdir: cannot create directory '/home/dev/.devcontainer': Read-only file system\n"}
        end
      ])

      assert Lifecycle.run(params(), ctx) ==
               {:error,
                "couldn't record that the onCreateCommand ran (in /home/dev/.devcontainer, as dev): " <>
                  "mkdir: cannot create directory '/home/dev/.devcontainer': Read-only file system"}

      assert user_commands(execs()) == []
    end

    # The container stopped under it: docker's own exit 1, not the script's.
    test "docker failing to run a marker's script isn't 'already ran'", %{ctx: ctx} do
      container([
        fn exec ->
          if match?(%{command: [_, _, "mkdir -p " <> _]}, exec),
            do: {1, "Error response from daemon: container abc is not running\n"}
        end
      ])

      assert {:error, "couldn't record that the onCreateCommand ran" <> _} =
               Lifecycle.run(params(), ctx)

      assert user_commands(execs()) == []
    end

    test "markers that can't be kept don't matter when there's nothing to run", %{ctx: ctx} do
      for status <- [1, 2, 21, 125] do
        container([
          fn exec ->
            if match?(%{command: [_, _, "mkdir -p " <> _]}, exec), do: {status, "nope\n"}
          end
        ])

        origins = Map.new(params().origins, fn {hook, _} -> {hook, []} end)

        assert {:ok, %{remote_user: "dev"}} = Lifecycle.run(params(%{origins: origins}), ctx)
      end
    end

    test "a marker's script says apart 'already ran' and 'couldn't tell'", %{ctx: ctx} do
      container()
      assert {:ok, _} = Lifecycle.run(params(), ctx)

      %{command: [_, _, script]} =
        Enum.find(execs(), &match?(%{command: [_, _, "mkdir -p " <> _]}, &1))

      dir = Path.join(System.tmp_dir!(), "marker-#{System.unique_integer([:positive])}")
      script = String.replace(script, "/home/dev/.devcontainer", dir)

      assert {_, 0} = System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true)
      assert {_, 20} = System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true)

      # Written whole or not at all: a marker left empty would read as "already ran".
      assert File.ls!(dir) == [".onCreateCommandMarker"]

      # A folder where the marker goes can't be one, and the stamp doesn't end up inside it.
      File.rm!(Path.join(dir, ".onCreateCommandMarker"))
      File.mkdir!(Path.join(dir, ".onCreateCommandMarker"))
      assert {_, 21} = System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true)
      assert File.ls!(Path.join(dir, ".onCreateCommandMarker")) == []

      File.rm_rf!(dir)
      File.write!(dir, "a file where the folder goes")
      assert {_, 21} = System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true)
      File.rm!(dir)
    end
  end

  describe "dotfiles" do
    test "are installed after the create hooks and before the start hook", %{ctx: ctx} do
      container()
      dotfiles = %{repository: "nate/dotfiles", install_command: nil, target_path: nil}

      assert {:ok, _} = Lifecycle.run(params(%{dotfiles: dotfiles}), ctx)

      all = execs()

      index =
        Enum.find_index(
          all,
          &match?(%{command: ["/bin/sh", "-c", "# Clone & install dotfiles" <> _]}, &1)
        )

      assert %{user: "dev", command: [_, _, script]} = Enum.at(all, index)

      assert script =~ "[ -e ~/dotfiles ] || HOME='/home/dev' "

      assert script =~
               "git clone --depth 1 https://github.com/nate/dotfiles.git ~/dotfiles || exit $?"

      assert script =~
               "for f in install.sh install bootstrap.sh bootstrap script/bootstrap setup.sh setup script/setup\n"

      assert script =~ "test ! -f '/home/dev/.devcontainer/.dotfilesMarker'"

      post_create = Enum.find_index(all, &(&1.command == ["/bin/sh", "-c", "echo post-create"]))
      post_start = Enum.find_index(all, &(&1.command == ["/bin/sh", "-c", "echo started"]))
      assert post_create < index and index < post_start
    end

    test "run the install command they're given, from where they're cloned to", %{ctx: ctx} do
      container()

      dotfiles = %{
        repository: "https://example.com/d.git",
        install_command: "setup/it's.sh",
        target_path: "~/.dots"
      }

      assert {:ok, _} = Lifecycle.run(params(%{dotfiles: dotfiles}), ctx)

      assert %{command: [_, _, script]} =
               Enum.find(
                 execs(),
                 &match?(%{command: ["/bin/sh", "-c", "# Clone & install dotfiles via" <> _]}, &1)
               )

      assert script =~ "git clone --depth 1 https://example.com/d.git ~/.dots || exit $?"
      assert script =~ ~s(if [ -f "./setup/it's.sh" ])
    end

    test "that fail don't fail the environment", %{ctx: ctx} do
      container([
        fn exec ->
          if match?(%{command: [_, _, "# Clone & install dotfiles" <> _]}, exec),
            do: {128, "fatal: nope\n"}
        end
      ])

      dotfiles = %{repository: "nate/dotfiles", install_command: nil, target_path: nil}

      assert {:ok, _} = Lifecycle.run(params(%{dotfiles: dotfiles}), ctx)
      assert logged() =~ "fatal: nope\n"
    end
  end
end
