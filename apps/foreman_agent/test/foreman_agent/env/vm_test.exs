defmodule ForemanAgent.Env.VmTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, RunnerMock}
  alias ForemanAgent.Env.Vm
  alias ForemanAgent.Guest.Wire

  @moduletag :tmp_dir

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @name "fm-6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    release = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(release, "bin"))
    File.write!(Path.join(release, "bin/foreman_agent"), "#!/bin/sh\n")

    config = %Config{
      data_dir: Path.join(tmp, "data"),
      envs_root: Path.join(tmp, "envs"),
      secrets_root: Path.join(tmp, "run"),
      release_root: Path.join(tmp, "opt"),
      isolation: :vm,
      incus: "incus",
      vm_image: "foreman-env",
      vm_profiles: [],
      vm_cpus: 6,
      vm_memory_mb: 8192,
      vm_disk_gb: 64,
      vm_release_dir: release,
      vm_policy_rules: Config.vm_default_rules(),
      allowed_git_hosts: ["github.com"]
    }

    File.mkdir_p!(config.data_dir)
    test_pid = self()
    log = fn stream, data -> send(test_pid, {:log, stream, data}) end
    {:ok, world} = Agent.start_link(fn -> %{vms: %{}, release: false, pushed: %{}} end)

    %{
      config: config,
      world: world,
      ctx: %{config: config, runner: RunnerMock, docker: DockerMock, log: log}
    }
  end

  defp payload(type, overrides \\ %{}) do
    base =
      case type do
        t when t in ["env.create", "env.rebuild"] ->
          %{
            "repo" => "acme/storefront",
            "clone_url" => "https://github.com/acme/storefront.git",
            "branch" => "main",
            "files" => %{"secrets.env" => "export A='1'\n", "github-token" => "ghu_secret"},
            "compose_env" => %{"NEON_API_KEY" => "neon_secret"}
          }

        "env.secrets.write" ->
          %{"files" => %{"secrets.env" => "export A='2'\n"}}

        "env.start" ->
          %{"compose_env" => %{}}

        _ ->
          %{}
      end

    ids =
      if type == "env.secrets.write",
        do: %{"env_id" => @env_id},
        else: %{"env_id" => @env_id, "slug" => "storefront-2"}

    {:ok, cmd} = ForemanProtocol.Command.new(type, Map.merge(ids, Map.merge(base, overrides)))

    cmd.payload
  end

  # A fake incus: VMs with a state, files pushed into them, and a guest
  # runner whose answer each test chooses.
  defp fake_incus(world, guest \\ fn _type, _payload -> {[], {:ok, %{}}} end) do
    test_pid = self()

    stub(RunnerMock, :run, fn
      "sh", ["-c", script, "incus" | args], opts ->
        if script =~ "tar -C" do
          # The release, piped into the VM.
          send(test_pid, {:release_pushed, args})
          Agent.update(world, &%{&1 | release: true})
          {:ok, %{status: 0, output: ""}}
        else
          send(test_pid, {:incus, args})
          incus(world, args, opts, guest)
        end

      command, args, _opts ->
        flunk("unexpected command: #{command} #{inspect(args)}")
    end)
  end

  defp incus(world, ["query", "/1.0/instances/" <> name], _opts, _guest) do
    case Agent.get(world, &get_in(&1, [:vms, name])) do
      nil -> {:ok, %{status: 1, output: "Error: Instance not found\n"}}
      vm -> {:ok, %{status: 0, output: JSON.encode!(%{"status" => vm.status})}}
    end
  end

  defp incus(world, ["init", _image, name, "--vm" | rest], _opts, _guest) do
    Agent.update(world, &put_in(&1, [:vms, name], %{status: "Stopped", args: rest}))
    {:ok, %{status: 0, output: ""}}
  end

  defp incus(world, ["start", name], _opts, _guest) do
    Agent.update(world, &put_in(&1, [:vms, name, :status], "Running"))
    {:ok, %{status: 0, output: ""}}
  end

  defp incus(world, ["stop", name | _], _opts, _guest) do
    Agent.update(world, &put_in(&1, [:vms, name, :status], "Stopped"))
    {:ok, %{status: 0, output: ""}}
  end

  defp incus(world, ["delete", name, "--force"], _opts, _guest) do
    Agent.update(world, fn w -> %{w | vms: Map.delete(w.vms, name)} end)
    {:ok, %{status: 0, output: ""}}
  end

  defp incus(world, ["list", "--format", "json"], _opts, _guest) do
    vms =
      for {name, vm} <- Agent.get(world, & &1.vms) do
        %{
          "name" => name,
          "status" => vm.status,
          "config" => %{"user.foreman.env_id" => @env_id, "user.foreman.slug" => "storefront-2"},
          "state" => %{"cpu" => %{"usage" => 0}, "memory" => %{"usage" => 0}}
        }
      end

    {:ok, %{status: 0, output: JSON.encode!(vms)}}
  end

  defp incus(world, ["file", "push" | rest], _opts, _guest) do
    [local, dest] = Enum.take(rest, -2)
    Agent.update(world, &put_in(&1, [:pushed, dest], File.read!(local)))
    {:ok, %{status: 0, output: ""}}
  end

  defp incus(world, ["exec", _name | rest], opts, guest) do
    argv = rest |> Enum.drop_while(&(&1 != "--")) |> tl()

    case argv do
      ["true"] ->
        {:ok, %{status: 0, output: ""}}

      ["curl" | _] ->
        {:ok, %{status: 0, output: Agent.get(world, &Map.get(&1, :containers, "[]"))}}

      ["test", "-x", _] ->
        {:ok, %{status: if(Agent.get(world, & &1.release), do: 0, else: 1), output: ""}}

      ["flock" | _] ->
        [expr] = Enum.take(argv, -1)
        [_, path] = Regex.run(~r/main\("([^"]+)"\)/, expr)
        request = Agent.get(world, &get_in(&1, [:pushed, @name <> path]))
        {:ok, {type, payload}} = Wire.decode_request(request)
        send(self(), {:guest_op, type, payload})
        {logs, result} = guest.(type, payload)

        for {stream, data} <- logs, do: opts[:on_output].(Wire.log(stream, data))
        opts[:on_output].("some release boot noise\n")
        if result != :none, do: opts[:on_output].(Wire.result(result))
        {:ok, %{status: 0, output: ""}}

      other ->
        flunk("unexpected exec: #{inspect(other)}")
    end
  end

  defp put_vm(world, status) do
    Agent.update(world, &put_in(&1, [:vms, @name], %{status: status, args: []}))
  end

  # Only the incus calls: guest operations stay in the mailbox for the
  # test's own assertions.
  defp incus_calls(acc \\ []) do
    receive do
      {:incus, args} -> incus_calls([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "create" do
    test "makes a VM sized from the environment's limits, then runs the create inside it",
         %{ctx: ctx, world: world} do
      fake_incus(world, fn "env.create", _ ->
        {[{"info", "Building image\n"}],
         {:ok, %{"container_id" => "abc123", "remote_user" => "vscode"}}}
      end)

      p = payload("env.create", %{"limits" => %{"cpus" => 2.5, "memory_mb" => 6144}})
      assert {:ok, result} = Vm.run("env.create", p, ctx)

      assert result["container_id"] == "abc123"
      assert result["isolation"] == "vm"
      assert result["vm"] == %{"name" => @name, "cpus" => 3, "memory_mb" => 6144}

      calls = incus_calls()
      init = Enum.find(calls, &match?(["init" | _], &1))
      assert "limits.cpu=3" in init
      assert "limits.memory=6144MiB" in init
      assert ["start", @name] in calls

      # The guest got the whole payload, secrets and all, by file, not argv.
      assert_received {:guest_op, "env.create", %{files: %{"github-token" => "ghu_secret"}}}
      refute Enum.any?(calls, fn args -> Enum.any?(args, &(&1 =~ "ghu_secret")) end)

      # Guest logs are relayed; its other output isn't passed off as a log.
      assert_received {:log, "info", "Building image\n"}
    end

    test "without limits, the VM gets the box's default size", %{ctx: ctx, world: world} do
      fake_incus(world)

      assert {:ok, %{"vm" => %{"cpus" => 6, "memory_mb" => 8192}}} =
               Vm.run("env.create", payload("env.create"), ctx)
    end

    test "keeps a host copy of the secrets, so a VM reboot can get them back",
         %{ctx: ctx, config: config, world: world} do
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.create", payload("env.create"), ctx)
      assert File.read!(Path.join([config.secrets_root, @env_id, "github-token"])) == "ghu_secret"
    end

    test "pushes this agent's release into the VM once", %{ctx: ctx, world: world} do
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.create", payload("env.create"), ctx)
      assert_received {:release_pushed, _}
      assert {:ok, _} = Vm.run("env.rebuild", payload("env.rebuild"), ctx)
      refute_received {:release_pushed, _}
    end

    test "reuses a VM that exists, starting it if it's stopped", %{ctx: ctx, world: world} do
      put_vm(world, "Stopped")
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.create", payload("env.create"), ctx)
      calls = incus_calls()
      refute Enum.any?(calls, &match?(["init" | _], &1))
      assert ["start", @name] in calls
    end

    test "the guest's error is the operation's error", %{ctx: ctx, world: world} do
      fake_incus(world, fn _, _ -> {[], {:error, "devcontainer up failed: build failed"}} end)

      assert {:error, "devcontainer up failed: build failed"} =
               Vm.run("env.create", payload("env.create"), ctx)
    end

    test "a guest that exits without a result is an error, with what it printed",
         %{ctx: ctx, world: world} do
      fake_incus(world, fn _, _ -> {[], :none} end)
      assert {:error, message} = Vm.run("env.create", payload("env.create"), ctx)
      assert message =~ "without a result"
      assert message =~ "boot noise"
    end

    test "the request file doesn't stay on the box", %{ctx: ctx, config: config, world: world} do
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.create", payload("env.create"), ctx)
      assert Path.wildcard(Path.join(config.data_dir, "**/*.op")) == []
    end
  end

  describe "stop and start" do
    test "stop stops the environment, then shuts the VM down", %{ctx: ctx, world: world} do
      put_vm(world, "Running")
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.stop", payload("env.stop"), ctx)
      assert_received {:guest_op, "env.stop", _}
      assert Agent.get(world, & &1.vms[@name].status) == "Stopped"
    end

    test "stopping a VM that's already down does nothing", %{ctx: ctx, world: world} do
      put_vm(world, "Stopped")
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.stop", payload("env.stop"), ctx)
      refute_received {:guest_op, _, _}
    end

    test "start boots the VM, puts the secrets back, then starts the environment",
         %{ctx: ctx, config: config, world: world} do
      put_vm(world, "Stopped")
      Agent.update(world, &%{&1 | release: true})
      dir = Path.join(config.secrets_root, @env_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "secrets.env"), "export B=1\n")
      fake_incus(world)

      assert {:ok, _} = Vm.run("env.start", payload("env.start"), ctx)
      assert ["start", @name] in incus_calls()

      assert_received {:guest_op, "env.secrets.write",
                       %{files: %{"secrets.env" => "export B=1\n"}}}

      assert_received {:guest_op, "env.start", _}
    end

    test "starting an environment whose VM is gone says to rebuild", %{ctx: ctx, world: world} do
      fake_incus(world)
      assert {:error, message} = Vm.run("env.start", payload("env.start"), ctx)
      assert message =~ "rebuild"
    end
  end

  describe "secrets" do
    test "updates the host copy, and the VM's when it's running", %{
      ctx: ctx,
      config: config,
      world: world
    } do
      put_vm(world, "Running")
      Agent.update(world, &%{&1 | release: true})
      fake_incus(world)

      assert {:ok, _} = Vm.run("env.secrets.write", payload("env.secrets.write"), ctx)

      assert File.read!(Path.join([config.secrets_root, @env_id, "secrets.env"])) ==
               "export A='2'\n"

      assert_received {:guest_op, "env.secrets.write", _}
    end

    test "with the VM stopped, only the host copy changes", %{
      ctx: ctx,
      config: config,
      world: world
    } do
      put_vm(world, "Stopped")
      fake_incus(world)

      assert {:ok, _} = Vm.run("env.secrets.write", payload("env.secrets.write"), ctx)
      assert File.exists?(Path.join([config.secrets_root, @env_id, "secrets.env"]))
      refute_received {:guest_op, _, _}
    end
  end

  describe "destroy, logs and git status" do
    test "destroy deletes the VM and the host's copies", %{ctx: ctx, config: config, world: world} do
      put_vm(world, "Running")
      File.mkdir_p!(Path.join(config.secrets_root, @env_id))
      fake_incus(world)

      assert {:ok, _} = Vm.run("env.destroy", payload("env.destroy"), ctx)
      assert Agent.get(world, & &1.vms) == %{}
      refute File.exists?(Path.join(config.secrets_root, @env_id))
    end

    test "destroying an environment with no VM succeeds", %{ctx: ctx, world: world} do
      fake_incus(world)
      assert {:ok, _} = Vm.run("env.destroy", payload("env.destroy"), ctx)
    end

    test "logs and git status need the VM running", %{ctx: ctx, world: world} do
      put_vm(world, "Stopped")
      fake_incus(world)
      assert {:error, message} = Vm.run("env.logs", payload("env.logs"), ctx)
      assert message =~ "stopped"
      assert {:error, _} = Vm.run("env.git_status", payload("env.git_status"), ctx)
    end

    test "git status runs in the guest", %{ctx: ctx, world: world} do
      put_vm(world, "Running")
      Agent.update(world, &%{&1 | release: true})
      fake_incus(world, fn "env.git_status", _ -> {[], {:ok, %{"dirty" => false}}} end)
      assert {:ok, %{"dirty" => false}} = Vm.run("env.git_status", payload("env.git_status"), ctx)
    end
  end

  describe "inventory" do
    test "a running VM reports its containers' state, under the slug the host gave it",
         %{ctx: ctx, world: world} do
      put_vm(world, "Running")

      containers = [
        %{
          "Id" => "abc",
          "State" => "running",
          # Labels inside the VM are the guest's to set.
          "Labels" => %{
            "foreman.env_id" => @env_id,
            "foreman.slug" => "something-else",
            "com.docker.compose.service" => "app"
          }
        }
      ]

      Agent.update(world, &Map.put(&1, :containers, JSON.encode!(containers)))
      fake_incus(world)

      assert {:ok, [%{env_id: @env_id, slug: "storefront-2", state: "running"}]} =
               Vm.inventory(ctx)
    end

    test "a running VM that can't say what's in it is partial, never missing",
         %{ctx: ctx, world: world} do
      put_vm(world, "Running")
      Agent.update(world, &Map.put(&1, :containers, "not json"))
      fake_incus(world)

      assert {:ok, [%{state: "partial"}]} = Vm.inventory(ctx)
    end
  end
end
