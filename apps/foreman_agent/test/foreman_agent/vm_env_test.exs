defmodule ForemanAgent.VMEnvTest do
  # The box's side of environment commands, against a guest agent in this
  # VM (ForemanAgent.Test.FakeMachine). Changes the cached config, so not
  # async.
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{Config, Handler, VM}
  alias ForemanAgent.Test.FakeMachine
  alias ForemanAgent.VM.{Links, Status}
  alias ForemanProtocol.Command

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @other "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  setup :set_mox_global

  setup do
    dir = Path.join("/tmp", "fmv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    saved = Config.get()

    on_exit(fn ->
      for env <- [@env, @other], do: Links.stop(env) && FakeMachine.kill(env, nil)
      Config.put(saved)
      File.rm_rf(dir)
    end)

    {tar, sha} = guest_image(dir)

    config = %{
      saved
      | mode: :host,
        vm_root: Path.join(dir, "vms"),
        guest_root: Path.join(dir, "guest"),
        agent_disks: Path.join(dir, "agent"),
        secrets_root: Path.join(dir, "run"),
        machine: FakeMachine,
        guest_url: "file://" <> tar,
        guest_sha256: sha,
        allowed_git_hosts: ["github.com"],
        vm_boot_timeout: 2_000,
        proc: Path.join(dir, "proc")
    }

    # A 32 GB box, whatever this machine is.
    File.mkdir_p!(config.proc)
    File.write!(Path.join(config.proc, "meminfo"), "MemTotal:       33554432 kB\n")

    Config.put(config)

    # The agent disk this agent would make from its release.
    File.mkdir_p!(config.agent_disks)
    File.write!(Path.join(config.agent_disks, "#{ForemanAgent.Identity.version()}.img"), "disk")

    # cp --reflink=auto --sparse=always SRC DEST, as the box's cp would.
    stub(ForemanAgent.RunnerMock, :run, fn
      "cp", [_, _, src, dest], _opts ->
        File.cp!(src, dest)
        {:ok, %{status: 0, output: ""}}

      "df", _, _ ->
        {:ok,
         %{
           status: 0,
           output: "Filesystem 1024-blocks Used Available\n/dev/x 1048576 0 524288 0% /\n"
         }}
    end)

    test = self()

    FakeMachine.configure(
      test: test,
      handler: fn cmd, log ->
        send(test, {:guest, cmd.type, cmd.payload})
        log.("stdout", "in the guest: #{cmd.type}\n")
        {:ok, %{"ran" => cmd.type}}
      end
    )

    ctx = %{
      config: config,
      runner: ForemanAgent.RunnerMock,
      docker: ForemanAgent.DockerMock,
      log: fn stream, data -> send(test, {:log, stream, data}) end
    }

    %{dir: dir, config: config, ctx: ctx, sha: sha}
  end

  # A guest image as guest/build.sh makes it: a tarball of the kernel, a
  # zstd root disk and a manifest.
  defp guest_image(dir) do
    src = Path.join(dir, "image")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "manifest.json"), ~s({"format":1}))
    File.write!(Path.join(src, "vmlinuz"), "kernel")
    File.write!(Path.join(src, "root.raw.zst"), :zstd.compress("root disk"))
    tar = Path.join(dir, "guest.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        for(
          f <- ~w(manifest.json vmlinuz root.raw.zst),
          do: {String.to_charlist(f), String.to_charlist(Path.join(src, f))}
        )
      )

    sha = :crypto.hash(:sha256, File.read!(tar)) |> Base.encode16(case: :lower)
    {tar, sha}
  end

  defp command(type, extra \\ %{})

  defp command("env.secrets.write", extra) do
    {:ok, cmd} = Command.new("env.secrets.write", Map.merge(%{env_id: @env}, extra))
    cmd
  end

  defp command(type, extra) do
    {:ok, cmd} = Command.new(type, Map.merge(%{env_id: @env, slug: "hello-1"}, extra))
    cmd
  end

  defp create(extra \\ %{}) do
    command(
      "env.create",
      Map.merge(
        %{
          repo: "acme/hello",
          clone_url: "https://github.com/acme/hello.git",
          branch: "main",
          files: %{"secrets.env" => "TOKEN=1\n"}
        },
        extra
      )
    )
  end

  defp run(cmd, %{ctx: ctx}), do: VM.Env.run(cmd, ctx.log, ctx)

  describe "env.create" do
    test "makes and boots the VM, writes its secrets, then runs the create in it", ctx do
      sha = ctx.sha
      assert {:ok, %{"ran" => "env.create"}} = run(create(), ctx)

      assert_received {:machine, {:boot, %{guest: ^sha, cpus: cpus, memory_mb: memory}}, @env}
      assert cpus == min(4, System.schedulers_online())
      assert memory == 8192
      assert_receive {:guest, "env.secrets.write", %{files: %{"secrets.env" => "TOKEN=1\n"}}}
      assert_receive {:guest, "env.create", %{slug: "hello-1"}}
      assert_receive {:log, "stdout", "in the guest: env.create\n"}

      paths = VM.paths(ctx.config, @env)
      assert File.read!(paths.root) == "root disk"
      assert File.stat!(paths.data).size == ctx.config.vm_disk_gb * 1024 * 1024 * 1024
      assert {:ok, %{"slug" => "hello-1", "guest" => ^sha}} = VM.read_meta(ctx.config, @env)

      # The box keeps the secrets too, for the next boot.
      secret = Path.join([ctx.config.secrets_root, @env, "secrets.env"])
      assert File.read!(secret) == "TOKEN=1\n"
      assert File.stat!(secret).mode |> Bitwise.band(0o777) == 0o600
    end

    test "sizes the VM from the environment's limits", ctx do
      assert {:ok, _} = run(create(%{limits: %{cpus: 1.5, memory_mb: 3072}}), ctx)
      assert_received {:machine, {:boot, %{cpus: cpus, memory_mb: 3072}}, @env}
      assert cpus == min(2, System.schedulers_online())
    end

    test "refuses a clone host the box doesn't allow, before making anything", ctx do
      assert {:error, "cloning from evil.example isn't allowed" <> _} =
               run(create(%{clone_url: "https://evil.example/x.git"}), ctx)

      refute_received {:machine, _, _}
      refute File.exists?(VM.paths(ctx.config, @env).dir)
    end

    test "refuses a guest image that doesn't match its SHA-256", ctx do
      Config.put(%{ctx.config | guest_sha256: String.duplicate("0", 64)})
      ctx = put_in(ctx.ctx.config, Config.get())
      assert {:error, "the guest image doesn't match its SHA-256" <> _} = run(create(), ctx)
      refute_received {:machine, _, _}
    end

    test "says so when the VM's agent never answers", ctx do
      FakeMachine.configure(test: self(), boot: :hang)
      assert {:error, "the environment's VM didn't come up" <> _} = run(create(), ctx)
    end

    test "a second create on a running VM doesn't boot it again", ctx do
      assert {:ok, _} = run(create(), ctx)
      assert_received {:machine, {:boot, _}, @env}
      assert {:ok, _} = run(create(), ctx)
      refute_received {:machine, {:boot, _}, @env}
    end
  end

  describe "a VM that's stopped" do
    setup ctx do
      {:ok, _} = run(create(), ctx)
      {:ok, _} = run(command("env.stop"), ctx)
      flush()
      :ok
    end

    test "is shut down after the environment's own stop", ctx do
      refute FakeMachine.running?(@env, ctx.config)
    end

    test "starts again with the secrets the box kept", ctx do
      {:ok, _} = run(command("env.secrets.write", %{files: %{"secrets.env" => "TOKEN=2\n"}}), ctx)
      refute_received {:guest, _, _}

      assert {:ok, %{"ran" => "env.start"}} = run(command("env.start"), ctx)
      assert_received {:machine, {:boot, _}, @env}
      assert_receive {:guest, "env.secrets.write", %{files: %{"secrets.env" => "TOKEN=2\n"}}}
      assert_receive {:guest, "env.start", _}
    end

    test "can't run what needs it running", ctx do
      assert {:error, "the environment isn't running"} = run(command("env.logs"), ctx)
      assert {:error, "the environment isn't running"} = run(command("env.git_status"), ctx)
    end

    test "stops again without a fuss", ctx do
      assert {:ok, %{}} = run(command("env.stop"), ctx)
      refute_received {:machine, :power_off, _}
    end
  end

  test "env.stop runs the environment's stop, then powers the VM off", ctx do
    {:ok, _} = run(create(), ctx)
    assert {:ok, %{"ran" => "env.stop"}} = run(command("env.stop"), ctx)
    assert_receive {:guest, "env.stop", _}
    assert_received {:machine, :power_off, @env}
  end

  test "a secrets write while running goes to the guest too", ctx do
    {:ok, _} = run(create(), ctx)
    flush()
    {:ok, _} = run(command("env.secrets.write", %{files: %{"notices" => "hi\n"}}), ctx)
    assert_receive {:guest, "env.secrets.write", %{files: %{"notices" => "hi\n"}}}
  end

  test "env.start with no VM says how to get one", ctx do
    assert {:error, "this environment has no VM on this box" <> _} =
             run(command("env.start"), ctx)
  end

  test "env.destroy gives back the VM and removes its disks and secrets", ctx do
    {:ok, _} = run(create(), ctx)
    assert {:ok, %{}} = run(command("env.destroy"), ctx)
    assert_received {:machine, :release, @env}
    refute File.exists?(VM.paths(ctx.config, @env).dir)
    refute File.exists?(Path.join(ctx.config.secrets_root, @env))
  end

  test "commands go through the handler's redaction on a box", ctx do
    {:ok, _} = run(create(), ctx)
    test = self()
    # The next boot gets a guest that prints what it was given.
    {:ok, _} = run(command("env.stop"), ctx)

    {:ok, cmd} =
      Command.new("env.start", %{
        env_id: @env,
        slug: "hello-1",
        compose_env: %{"T" => "s3cret-value"}
      })

    FakeMachine.configure(
      test: test,
      handler: fn _cmd, log ->
        log.("stdout", "value s3cret-value\n")
        {:ok, %{}}
      end
    )

    assert {:ok, _} =
             Handler.handle(cmd, fn stream, data -> send(test, {:handler_log, stream, data}) end)

    assert_receive {:handler_log, "stdout", line}
    refute line =~ "s3cret-value"
  end

  describe "the box's reports" do
    setup ctx do
      test = self()

      FakeMachine.configure(
        test: test,
        handler: fn _cmd, _log -> {:ok, %{}} end,
        queries: %{
          "inventory" => fn ->
            {:ok,
             [
               %{
                 "env_id" => @other,
                 "slug" => "evil-1",
                 "state" => "running",
                 "containers" => []
               },
               %{
                 "env_id" => @env,
                 "slug" => "made-up",
                 "state" => "running",
                 "containers" => [%{"id" => "c1", "service" => "app", "state" => "running"}]
               }
             ]}
          end,
          "ports" => fn ->
            {:ok,
             %{
               @env => [%{"port" => 4000, "process" => "beam.smp"}],
               @other => [%{"port" => 22}]
             }}
          end
        }
      )

      {:ok, _} = run(create(), ctx)
      :ok
    end

    test "inventory takes only the VM's own environment, under its own slug", ctx do
      assert {:ok, [entry]} = Status.inventory(ctx.config)
      assert entry.env_id == @env
      assert entry.slug == "hello-1"
      assert entry.state == "running"
      assert [%{id: "c1", service: "app"}] = entry.containers
    end

    test "inventory shows a stopped VM as stopped", ctx do
      FakeMachine.kill(@env, ctx.config)

      assert {:ok, [%{env_id: @env, state: "stopped", containers: []}]} =
               Status.inventory(ctx.config)
    end

    test "ports takes only the VM's own environment", ctx do
      assert Status.ports(ctx.config) == %{@env => [%{port: 4000, process: "beam.smp"}]}
    end

    test "stats come from the VM, not the guest", ctx do
      assert {:ok, %{capacity: %{cpus: cpus}, environments: %{@env => usage}}} =
               Status.stats(ctx.ctx)

      assert cpus == System.schedulers_online()
      assert usage.memory_mb == 512
    end
  end

  test "a VM's size never passes the box's" do
    config = %Config{vm_cpus: 4, vm_memory_mb: 8192}
    box = %{cpus: 2, memory_mb: 4096}
    assert VM.size(%{}, config, box) == %{cpus: 2, memory_mb: 4096}

    assert VM.size(%{cpus: 0.5, memory_mb: 100}, config, %{cpus: 8, memory_mb: 65_536}) == %{
             cpus: 1,
             memory_mb: 512
           }

    assert VM.size(%{cpus: 3}, config, %{cpus: 8, memory_mb: 65_536}) == %{
             cpus: 3,
             memory_mb: 8192
           }
  end

  defp flush do
    receive do
      _ -> flush()
    after
      50 -> :ok
    end
  end
end
