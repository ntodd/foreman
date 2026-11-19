defmodule ForemanAgent.VMEnvTest do
  # The box's side of environment commands, against a guest agent in this
  # VM (ForemanAgent.Test.FakeMachine). Changes the cached config, so not
  # async.
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{Config, Handler, VM}
  alias ForemanAgent.Test.FakeMachine
  alias ForemanAgent.VM.{Links, Reclaimer, Status}
  alias ForemanProtocol.Command

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @other "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"
  @prebuild "3c2b1a09-8f7e-4d6c-9b5a-1e2d3c4b5a69"

  setup :set_mox_global

  setup do
    dir = Path.join("/tmp", "fmv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    saved = Config.get()

    on_exit(fn ->
      for env <- [@env, @other, @prebuild], do: Links.stop(env) && FakeMachine.kill(env, nil)
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
        prebuilds_root: Path.join(dir, "prebuilds"),
        secrets_root: Path.join(dir, "run"),
        machine: FakeMachine,
        guest_url: "file://" <> tar,
        guest_sha256: sha,
        allowed_git_hosts: ["github.com"],
        vm_boot_timeout: 2_000,
        vm_relay_stop_timeout: 500,
        prebuild_timeout: 1_000,
        vm_relay_gc_timeout: 500,
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
      "mkfs.ext4", ["-q", "-F", "-L", "fm-data", "-d", seed, "-E", _, path, size], _opts ->
        assert File.read!(Path.join(seed, ".env-id")) =~ ~r/^[0-9a-f-]{36}\n$/
        {gb, "G"} = Integer.parse(size)

        File.open!(path, [:write, :exclusive], fn fd ->
          {:ok, _} = :file.position(fd, gb * 1024 * 1024 * 1024)
          :ok = :file.truncate(fd)
        end)

        {:ok, %{status: 0, output: ""}}

      "cp", [_, _, src, dest], _opts ->
        File.cp!(src, dest)
        {:ok, %{status: 0, output: ""}}

      "cp", ["--no-dereference" | _] = args, _opts ->
        {output, status} = System.cmd("cp", args, stderr_to_stdout: true)
        {:ok, %{status: status, output: output}}

      "node", [script, path, limit], _opts ->
        {output, status} = System.cmd("node", [script, path, limit], stderr_to_stdout: true)
        {:ok, %{status: status, output: output}}

      "sync", ["-f", _path], _opts ->
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

    test "a missing data disk on an established VM blocks start, rebuild and create retries",
         ctx do
      assert {:ok, _} = run(create(), ctx)
      assert {:ok, _} = run(command("env.suspend"), ctx)
      paths = VM.paths(ctx.config, @env)
      File.rename!(paths.data, paths.data <> ".saved")
      flush()

      for cmd <- [command("env.start"), %{create() | type: "env.rebuild"}, create()] do
        assert {:error, message} = run(cmd, ctx)
        assert message =~ "data disk is missing"
        refute File.exists?(paths.data)
        assert VM.suspended?(ctx.config, @env)
        refute_received {:machine, {:restore, _}, @env}
        refute_received {:machine, {:boot, _}, @env}
      end
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

    # The guest's secrets are on its tmpfs: a guest that rebooted itself,
    # or a boot whose push failed, has none.
    test "writes the secrets into a VM that was already running", ctx do
      assert {:ok, _} = run(create(), ctx)
      assert_receive {:guest, "env.secrets.write", _}
      assert {:ok, _} = run(command("env.start"), ctx)
      assert_receive {:guest, "env.secrets.write", %{files: %{"secrets.env" => "TOKEN=1\n"}}}
      assert_receive {:guest, "env.start", _}
      assert {:ok, _} = run(command("env.restart", %{mode: "all"}), ctx)
      assert_receive {:guest, "env.secrets.write", _}
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

    test "an unreadable cached file prevents the entire guest secrets write", ctx do
      File.mkdir!(Path.join([ctx.config.secrets_root, @env, "notices"]))
      assert {:error, message} = run(command("env.start"), ctx)
      assert message =~ "couldn't read cached notices"
      assert message =~ to_string(:file.format_error(:eisdir))
      refute message =~ "TOKEN=1"
      refute_received {:guest, "env.secrets.write", _}
      refute_received {:guest, "env.start", _}
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

  # A guest that hangs on one kind of command.
  defp hangs_on(type) do
    FakeMachine.configure(
      test: self(),
      handler: fn
        %{type: ^type}, _log -> Process.sleep(:infinity)
        _cmd, _log -> {:ok, %{}}
      end
    )
  end

  test "a stop powers the VM off even when the guest never finishes its part", ctx do
    hangs_on("env.stop")
    {:ok, _} = run(create(), ctx)

    assert {:ok, _} = run(command("env.stop"), ctx)
    assert_received {:machine, :power_off, @env}
    refute FakeMachine.running?(@env, ctx.config)
  end

  test "gc goes on past a guest that never finishes pruning", ctx do
    hangs_on("box.gc")
    {:ok, _} = run(create(), ctx)
    stale = Path.join(ctx.config.guest_root, String.duplicate("b", 64))
    File.mkdir_p!(stale)

    assert {:error, message} = Status.gc(ctx.ctx)
    assert message =~ "didn't finish it in time"
    refute File.exists?(stale)
  end

  test "a legacy VM gets its allocation from the start command", ctx do
    {:ok, _} = run(create(), ctx)
    {:ok, _} = run(command("env.stop"), ctx)
    paths = VM.paths(ctx.config, @env)
    File.rename!(paths.meta, paths.legacy_meta)
    {:ok, legacy} = VM.read_meta(ctx.config, @env)
    assert legacy["legacy"]
    refute Map.has_key?(legacy, "cpus")

    assert {:error, "update the control plane" <> _} = run(command("env.start"), ctx)
    flush()
    assert {:ok, _} = run(command("env.start", %{limits: %{cpus: 1, memory_mb: 1024}}), ctx)
    assert_received {:machine, {:boot, %{cpus: 1, memory_mb: 1024}}, @env}
    assert {:ok, %{"memory_mb" => 1024} = record} = VM.read_meta(ctx.config, @env)
    refute record["legacy"]
    assert Path.dirname(paths.meta) != paths.dir
  end

  test "the VM's record isn't written through a symlink the VM left beside it", ctx do
    {:ok, _} = run(create(), ctx)
    {:ok, _} = run(command("env.stop"), ctx)
    outside = Path.join(ctx.dir, "outside")
    File.write!(outside, "the agent's")
    File.ln_s!(outside, VM.paths(ctx.config, @env).meta <> ".tmp")

    assert {:ok, _} = run(command("env.start"), ctx)
    assert File.read!(outside) == "the agent's"
    assert {:ok, %{"slug" => _}} = VM.read_meta(ctx.config, @env)
  end

  test "the VM's record isn't read through a symlink the VM left in its place", ctx do
    {:ok, _} = run(create(), ctx)
    meta = VM.paths(ctx.config, @env).meta
    elsewhere = Path.join(ctx.dir, "elsewhere.json")
    File.cp!(meta, elsewhere)
    File.rm!(meta)
    File.ln_s!(elsewhere, meta)

    assert VM.read_meta(ctx.config, @env) == {:error, :none}
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

  test "failed release preserves the VM disks and cached files for a retry", ctx do
    {:ok, _} = run(create(), ctx)
    FakeMachine.configure(test: self(), release: {:error, "unit still active"})
    assert {:error, "unit still active"} = run(command("env.destroy"), ctx)
    assert {:error, "unit still active"} = VM.Prebuild.discard(ctx.config, @env)
    assert File.regular?(VM.paths(ctx.config, @env).data)
    assert File.regular?(Path.join([ctx.config.secrets_root, @env, "secrets.env"]))
  end

  test "env.destroy gives back the VM and removes its disks and secrets", ctx do
    {:ok, _} = run(create(), ctx)
    assert {:ok, %{}} = run(command("env.destroy"), ctx)
    assert_received {:machine, :release, @env}
    refute File.exists?(VM.paths(ctx.config, @env).dir)
    refute File.exists?(Path.join(ctx.config.secrets_root, @env))
  end

  test "destroy and prebuild deletion identify inaccessible storage and can be retried", ctx do
    {:ok, _} = run(create(), ctx)
    blocked = Path.join(ctx.dir, "unavailable-mount")
    File.write!(blocked, "")
    config = %{ctx.config | secrets_root: blocked, prebuilds_root: blocked}
    blocked_ctx = put_in(ctx.ctx.config, config)

    assert {:error, error} = run(command("env.destroy"), blocked_ctx)
    assert error =~ Path.join(blocked, @env)
    assert {:error, error} = VM.Prebuild.delete(@prebuild, %{config: config})
    assert error =~ Path.join(blocked, @prebuild)

    assert {:ok, %{}} = run(command("env.destroy"), ctx)
    assert {:ok, %{}} = run(command("env.destroy"), ctx)
    assert {:ok, %{}} = VM.Prebuild.delete(@prebuild, ctx)
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

  describe "suspend" do
    setup ctx do
      test = self()

      # A guest whose memory a resume keeps: its processes carry on.
      FakeMachine.configure(
        test: test,
        handler: fn cmd, log ->
          send(test, {:guest, cmd.type, cmd.payload})
          log.("stdout", "in the guest: #{cmd.type}\n")
          {:ok, %{"ran" => cmd.type, "guest" => inspect(self())}}
        end
      )

      {:ok, _} = run(create(), ctx)
      flush()
      :ok
    end

    test "reports a host OOM separately from ordinary stopped inventory", ctx do
      :ok = FakeMachine.kill(@env, ctx.config)
      FakeMachine.configure(oom_killed_at: 1_798_800_000)

      assert {:ok, [%{state: "stopped", oom_killed_at: 1_798_800_000}]} =
               Status.inventory(ctx.config)

      :ok = ForemanAgent.Outbox.attach(self())
      reporter = start_supervised!(ForemanAgent.Reporter)
      send(reporter, :inventory)

      assert_receive {:outbox_deliver,
                      %{type: "box.vm_oom", payload: %{environments: %{@env => 1_798_800_000}}},
                      _},
                     2000

      assert_receive {:outbox_deliver, %{type: "box.inventory", payload: %{environments: [wire]}},
                      _},
                     2000

      refute Map.has_key?(wire, :oom_killed_at)

      FakeMachine.configure([])
      assert {:ok, [entry]} = Status.inventory(ctx.config)
      refute Map.has_key?(entry, :oom_killed_at)
    end

    test "saves the VM and stops it; the box reports it suspended", ctx do
      assert {:ok, %{"suspended" => true}} = run(command("env.suspend"), ctx)
      assert_received {:machine, :snapshot, @env}
      refute FakeMachine.running?(@env, ctx.config)
      assert VM.suspended?(ctx.config, @env)
      refute File.exists?(VM.paths(ctx.config, @env).snapshot <> ".tmp")
      assert {:ok, [%{env_id: @env, state: "suspended"}]} = Status.inventory(ctx.config)
    end

    test "a start resumes it rather than booting, and drops the snapshot", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      flush()

      assert {:ok, %{"ran" => "env.start"}} = run(command("env.start"), ctx)
      assert_received {:machine, {:restore, %{cpus: _, memory_mb: _}}, @env}
      refute_received {:machine, {:boot, _}, @env}
      # The secrets go again: they may have changed while it was suspended.
      assert_receive {:guest, "env.secrets.write", _}
      assert_receive {:guest, "env.start", _}
      refute VM.suspended?(ctx.config, @env)
    end

    test "a resume that fails boots the VM instead", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      FakeMachine.kill(@env, ctx.config)
      flush()

      assert {:ok, _} = run(command("env.start"), ctx)
      assert_received {:machine, {:restore, _}, @env}
      assert_received {:machine, {:boot, _}, @env}

      assert_received {:log, "info",
                       "Couldn't resume the environment (nothing to restore); booting it instead\n"}

      refute VM.suspended?(ctx.config, @env)
    end

    test "a failed snapshot leaves it running", ctx do
      FakeMachine.configure(test: self(), snapshot: {:error, "no room"})
      assert {:error, "no room"} = run(command("env.suspend"), ctx)
      refute VM.suspended?(ctx.config, @env)
      refute File.exists?(VM.paths(ctx.config, @env).snapshot <> ".tmp")
    end

    test "a stop resumes it first, so the environment's own stop runs", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      flush()

      assert {:ok, %{"ran" => "env.stop"}} = run(command("env.stop"), ctx)
      assert_received {:machine, {:restore, _}, @env}
      assert_receive {:guest, "env.stop", _}
      assert_received {:machine, :power_off, @env}
      refute VM.suspended?(ctx.config, @env)
    end

    test "suspending one that isn't running is refused, and a suspended one again is fine", ctx do
      {:ok, _} = run(command("env.stop"), ctx)
      assert {:error, "the environment isn't running"} = run(command("env.suspend"), ctx)

      {:ok, _} = run(command("env.start"), ctx)
      {:ok, _} = run(command("env.suspend"), ctx)
      assert {:ok, %{"suspended" => true}} = run(command("env.suspend"), ctx)
    end

    test "a start after a resume says so", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      assert {:ok, %{"resumed" => true}} = run(command("env.start"), ctx)
      assert {:ok, result} = run(command("env.start"), ctx)
      refute Map.has_key?(result, "resumed")
    end

    # Cloud Hypervisor restores a snapshot only with the binary, guest
    # image and agent disk it was taken with.
    test "a box updated since the suspend starts the environment afresh", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      {:ok, meta} = VM.read_meta(ctx.config, @env)
      VM.write_meta(ctx.config, @env, put_in(meta, ["booted", "agent"], "0.0.1"))
      flush()

      assert {:ok, result} = run(command("env.start"), ctx)
      refute Map.has_key?(result, "resumed")
      refute_received {:machine, {:restore, _}, @env}
      assert_received {:machine, {:boot, _}, @env}
      refute VM.suspended?(ctx.config, @env)
    end

    test "a resume is the size it was suspended at, whatever the command asks", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      {:ok, %{"booted" => %{"memory_mb" => memory}}} = VM.read_meta(ctx.config, @env)
      flush()

      assert {:ok, _} =
               run(
                 command("env.rebuild", %{
                   repo: "acme/hello",
                   clone_url: "https://github.com/acme/hello.git",
                   branch: "main",
                   limits: %{memory_mb: 1024}
                 }),
                 ctx
               )

      assert_received {:machine, {:restore, %{memory_mb: ^memory}}, @env}
    end

    # Copy-on-write: once the VM is back the snapshot can go, and a stale
    # one beside a VM that has run since would restore old memory over a
    # changed disk.
    test "a snapshot beside a running VM is never restored", ctx do
      snapshot = VM.paths(ctx.config, @env).snapshot
      File.mkdir_p!(snapshot)
      File.write!(Path.join(snapshot, "config.json"), "{}")

      assert {:ok, _} = run(command("env.stop"), ctx)
      refute File.exists?(snapshot)
      flush()
      assert {:ok, _} = run(command("env.start"), ctx)
      refute_received {:machine, {:restore, _}, @env}
    end

    test "an interrupted restore reports a readiness timeout before relaying secrets", ctx do
      Links.stop(@env)
      :ok = FakeMachine.kill(@env, ctx.config)
      FakeMachine.configure(test: self(), boot: :hang)
      :ok = FakeMachine.boot(@env, %{}, ctx.config)
      snapshot = VM.paths(ctx.config, @env).snapshot
      File.mkdir_p!(snapshot)
      File.write!(Path.join(snapshot, "consumed"), "")
      flush()

      assert {:error, "the environment's VM didn't answer" <> _} = run(command("env.start"), ctx)
      refute FakeMachine.running?(@env, ctx.config)
      refute_received {:guest, "env.secrets.write", _}
    end

    test "a VM left paused is let go before anything is sent to it", ctx do
      assert {:ok, _} = run(command("env.start"), ctx)
      assert_received {:machine, :unpause, @env}
    end

    test "startup removes interrupted disk copies and extra links to published disks", ctx do
      paths = VM.paths(ctx.config, @env)

      staging = fn ->
        Path.join(
          ctx.config.vm_root,
          ".disk-" <> Base.url_encode64(:crypto.strong_rand_bytes(16))
        )
      end

      extra_link = staging.()
      interrupted_copy = staging.()
      other = Path.join(ctx.config.vm_root, ".disk-local")
      File.ln!(paths.data, extra_link)
      File.write!(interrupted_copy, "unfinished")
      File.write!(other, "local")
      original = File.stat!(paths.data)

      :ok = VM.Env.recover(ctx.config)
      refute File.exists?(extra_link)
      refute File.exists?(interrupted_copy)
      assert File.stat!(paths.data).inode == original.inode
      assert File.stat!(paths.data).links == original.links - 1
      assert File.read!(other) == "local"
    end

    test "at the agent's start, what a suspend cut short is cleaned up", ctx do
      paths = VM.paths(ctx.config, @env)
      File.mkdir_p!(paths.snapshot <> ".tmp")
      File.mkdir_p!(paths.snapshot)
      File.write!(Path.join(paths.snapshot, "config.json"), "{}")

      :ok = VM.Env.recover(ctx.config)
      refute File.exists?(paths.snapshot <> ".tmp")
      assert_received {:machine, :unpause, @env}
      # Beside a running VM, a snapshot waits for the guest to answer (its
      # VM may still be reading it), then goes; it's never restored.
      assert {:ok, _} = run(command("env.start"), ctx)
      refute_received {:machine, {:restore, _}, @env}
      refute File.exists?(paths.snapshot)

      # A suspended VM keeps its snapshot; one handed to a VM that's gone
      # since is discarded.
      {:ok, _} = run(command("env.suspend"), ctx)
      :ok = VM.Env.recover(ctx.config)
      assert VM.suspended?(ctx.config, @env)
      File.write!(Path.join(paths.snapshot, "consumed"), "")
      :ok = VM.Env.recover(ctx.config)
      refute File.exists?(paths.snapshot)
    end

    test "an outdated host helper leaves a suspended VM intact", ctx do
      assert {:ok, _} = run(command("env.suspend"), ctx)
      FakeMachine.configure(test: self(), ready: {:error, "reinstall the helper"})
      flush()

      for type <- ["env.start", "env.stop"] do
        assert {:error, "reinstall the helper"} = run(command(type), ctx)
        assert VM.suspended?(ctx.config, @env)
      end

      refute_received {:machine, {:restore, _}, @env}
    end

    test "a failed marker sync prevents restore and cold boot", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      flush()
      expect(ForemanAgent.RunnerMock, :run, fn "sync", ["-f", _], _ -> {:error, :eio} end)
      assert {:error, "couldn't sync " <> _} = run(command("env.start"), ctx)
      refute_received {:machine, {:restore, _}, @env}
      refute_received {:machine, {:boot, _}, @env}
    end

    test "a retried suspend must confirm the snapshot directory entry", ctx do
      paths = VM.paths(ctx.config, @env)
      expect(ForemanAgent.RunnerMock, :run, fn "sync", ["-f", _], _ -> {:ok, %{status: 0}} end)

      expect(ForemanAgent.RunnerMock, :run, 2, fn "sync", ["-f", path], _ ->
        assert path == paths.dir
        {:ok, %{status: 1}}
      end)

      for _ <- 1..2 do
        assert {:error, "couldn't sync " <> _} = run(command("env.suspend"), ctx)
      end

      expect(ForemanAgent.RunnerMock, :run, fn "sync", ["-f", _], _ -> {:ok, %{status: 0}} end)
      assert {:ok, %{"suspended" => true}} = run(command("env.suspend"), ctx)
    end

    test "a snapshot is marked used before the VM can run from it", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      assert {:ok, %{"resumed" => true}} = run(command("env.start"), ctx)
      assert_received {:machine, {:restore_saw_consumed, true}, @env}
    end

    # The snapshot is in the VM's directory, which the VM can write: a
    # symlink it left as the marker could have the agent write anywhere
    # the agent can.
    test "a marker the VM left as a symlink isn't written through, and the VM boots", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      outside = Path.join(ctx.dir, "outside")
      File.ln_s!(outside, Path.join(VM.paths(ctx.config, @env).snapshot, "consumed"))
      flush()

      assert {:ok, result} = run(command("env.start"), ctx)
      refute File.exists?(outside)
      refute Map.has_key?(result, "resumed")
      refute_received {:machine, {:restore, _}, @env}
      assert_received {:machine, {:boot, _}, @env}
    end

    # The agent stopped after handing the snapshot over and before the VM
    # was back, and the VM went down since: what's on disk has moved on.
    test "a snapshot that was handed over once is never restored again", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      File.write!(Path.join(VM.paths(ctx.config, @env).snapshot, "consumed"), "")
      refute VM.suspended?(ctx.config, @env)
      assert {:ok, [%{env_id: @env, state: "stopped"}]} = Status.inventory(ctx.config)
      flush()

      assert {:ok, result} = run(command("env.start"), ctx)
      refute Map.has_key?(result, "resumed")
      refute_received {:machine, {:restore, _}, @env}
      assert_received {:machine, {:boot, _}, @env}
      refute File.exists?(VM.paths(ctx.config, @env).snapshot)
    end

    test "a stop of a suspended environment that can't come back discards what was saved", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      # The guest image it needs can't be had.
      Config.put(%{ctx.config | guest_sha256: String.duplicate("0", 64)})
      ctx = put_in(ctx.ctx.config, Config.get())

      assert {:ok, _} = run(command("env.stop"), ctx)
      refute VM.suspended?(ctx.config, @env)
      refute File.exists?(VM.paths(ctx.config, @env).snapshot)
      refute FakeMachine.running?(@env, ctx.config)
    end

    # The box's agent restarted after resuming the VM and before reporting
    # it, and the control plane sent the start again.
    test "a start sent again after it resumed the VM still says it resumed", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      start = command("env.start")
      assert {:ok, %{"resumed" => true}} = run(start, ctx)
      op_id = start.op_id
      assert_received {:machine, {:resume_id_at_restore, ^op_id}, @env}
      assert {:ok, %{"resumed" => true}} = run(start, ctx)
      assert {:ok, result} = run(command("env.start"), ctx)
      refute Map.has_key?(result, "resumed")
    end

    test "destroy takes the snapshot with the rest", ctx do
      {:ok, _} = run(command("env.suspend"), ctx)
      assert {:ok, %{}} = run(command("env.destroy"), ctx)
      refute File.exists?(VM.paths(ctx.config, @env).dir)
    end
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
          end,
          "reclaim" => fn args ->
            send(test, {:reclaim_asked, args})

            {:ok,
             %{
               "requested_mb" => 4096,
               "file_before_mb" => 6144,
               "file_after_mb" => 2048,
               "free_before_mb" => 300,
               "free_after_mb" => 4396,
               "reclaim" => "ok",
               "compact" => "ok",
               "drain" => "ok",
               "reclaim_ms" => 700,
               "compact_ms" => 300,
               "drain_ms" => 40
             }}
          end
        }
      )

      {:ok, _} = run(create(), ctx)
      :ok
    end

    test "page cache reclaim samples the box, and each running VM from outside", ctx do
      File.write!(
        Path.join(ctx.config.proc, "meminfo"),
        "MemTotal:       33554432 kB\nMemFree:          100000 kB\nMemAvailable:    4194304 kB\n"
      )

      assert {:ok, sample} = Reclaimer.sample(ctx.config)
      assert sample.total_bytes == 32 * 1_073_741_824
      assert sample.available_bytes == 4 * 1_073_741_824
      assert %{@env => %{memory_bytes: 536_870_912, cpu_usec: cpu}} = sample.vms
      assert is_integer(cpu)
    end

    test "a box that can't read its memory can't sample", ctx do
      assert {:error, "couldn't read the box's memory from " <> _} = Reclaimer.sample(ctx.config)
    end

    test "page cache reclaim reaches the VM's guest agent", ctx do
      assert {:ok, %{reclaim: "ok", drain: "ok", free_after_mb: 4396}} =
               Reclaimer.reclaim(@env, 2048, ctx.config)

      assert_received {:reclaim_asked, %{"keep_mb" => 2048}}
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

    test "a console the guest fills is cut back", ctx do
      serial = VM.paths(ctx.config, @env).serial
      File.write!(serial, :binary.copy("x", 17 * 1024 * 1024))
      assert {:ok, _} = Status.stats(ctx.ctx)
      assert File.stat!(serial).size < 1024 * 1024
    end

    test "gc removes what an interrupted download or build left, and keeps what's in use", ctx do
      stale = Path.join(ctx.config.guest_root, ".abc.123")
      fresh = Path.join(ctx.config.guest_root, ".def.456")
      building = Path.join(ctx.config.agent_disks, ".9.9.9.img.tmp")
      for dir <- [stale, fresh], do: File.mkdir_p!(dir)
      File.write!(building, "half a disk")
      long_ago = :os.system_time(:second) - 7 * 3600
      File.touch!(stale, long_ago)

      assert {:ok, _} = Status.gc(ctx.ctx)
      refute File.exists?(stale)
      assert File.exists?(fresh)
      assert File.exists?(building)
      assert File.exists?(Path.join(ctx.config.guest_root, ctx.sha))
    end

    test "stats come from the VM, not the guest", ctx do
      assert {:ok, %{capacity: %{cpus: cpus}, environments: %{@env => usage}}} =
               Status.stats(ctx.ctx)

      assert cpus == System.schedulers_online()
      assert usage.memory_mb == 512
    end
  end

  test "a guest can't say its environment is suspended; only the box can" do
    entry = %{"env_id" => @env, "slug" => "x", "state" => "suspended", "containers" => []}
    assert VM.cast_inventory_entry([entry], @env, "hello-1") == :error

    assert {:ok, %{state: "running"}} =
             VM.cast_inventory_entry([%{entry | "state" => "running"}], @env, "hello-1")
  end

  describe "prebuilds" do
    # The handler's runner is the box's own; these go through the handler.
    setup do
      Application.put_env(:foreman_agent, :runner, ForemanAgent.RunnerMock)
      on_exit(fn -> Application.delete_env(:foreman_agent, :runner) end)
    end

    defp prebuild_command(extra \\ %{}) do
      {:ok, cmd} =
        Command.new(
          "box.prebuild",
          Map.merge(
            %{
              prebuild_id: @prebuild,
              repo: "acme/hello",
              clone_url: "https://github.com/acme/hello.git",
              branch: "main",
              files: %{"github-token" => "ghs_clonetoken"}
            },
            extra
          )
        )

      cmd
    end

    defp handle(cmd) do
      test = self()
      Handler.handle(cmd, fn stream, data -> send(test, {:handler_log, stream, data}) end)
    end

    defp prebuilt(config, content) do
      File.mkdir_p!(VM.Prebuild.dir(config, @prebuild))
      File.write!(VM.Prebuild.disk(config, @prebuild), content)
    end

    test "one is built in a VM of its own, and only its data disk is kept", ctx do
      assert {:ok, %{"prebuild_id" => @prebuild, "size_mb" => size}} = handle(prebuild_command())
      assert is_integer(size)

      assert_received {:machine, {:boot, _}, @prebuild}

      assert_receive {:guest, "env.secrets.write",
                      %{files: %{"github-token" => "ghs_clonetoken"}}}

      assert_receive {:guest, "env.create",
                      %{env_id: @prebuild, slug: "prebuild-3c2b1a09", prebuild: true} = create}

      refute Map.has_key?(create, :prebuild_id)
      assert_receive {:guest, "env.stop", %{env_id: @prebuild}}

      assert VM.Prebuild.exists?(ctx.config, @prebuild)

      assert {:ok, %{"repo" => "acme/hello", "branch" => "main"}} =
               ctx.config
               |> VM.Prebuild.dir(@prebuild)
               |> Path.join("prebuild.json")
               |> File.read!()
               |> JSON.decode()

      # The VM, its root disk and the token the box kept for it go.
      refute FakeMachine.running?(@prebuild, ctx.config)
      assert_received {:machine, :release, @prebuild}
      refute File.exists?(VM.paths(ctx.config, @prebuild).dir)
      refute File.exists?(Path.join(ctx.config.secrets_root, @prebuild))
    end

    unless :os.type() == {:unix, :linux}, do: @tag(skip: "requires a Linux tmpfs")

    test "publishes the complete prebuild on a separate filesystem", ctx do
      root = Path.join("/dev/shm", "foreman-prebuild-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      refute File.stat!(root).major_device == File.stat!(ctx.dir).major_device
      config = %{ctx.config | prebuilds_root: root}
      Config.put(config)

      assert {:ok, _} = handle(prebuild_command())

      assert File.stat!(VM.Prebuild.disk(config, @prebuild)).size ==
               config.vm_disk_gb * 1024 * 1024 * 1024

      assert File.ls!(root) == [@prebuild]
    end

    test "a build that fails keeps nothing, and says why without the token", ctx do
      test = self()

      FakeMachine.configure(
        test: test,
        handler: fn
          %{type: "env.create"}, _log -> {:error, "git clone failed: bad token ghs_clonetoken"}
          _cmd, _log -> {:ok, %{}}
        end
      )

      assert {:error, message} = handle(prebuild_command())
      assert message =~ "git clone failed"
      refute message =~ "ghs_clonetoken"
      refute VM.Prebuild.exists?(ctx.config, @prebuild)
      refute File.exists?(VM.paths(ctx.config, @prebuild).dir)
      refute File.exists?(Path.join(ctx.config.secrets_root, @prebuild))
    end

    test "an environment starts from a copy of the box's prebuild", ctx do
      prebuilt(ctx.config, "prebuilt disk")

      assert {:ok, _} = run(create(%{prebuild_id: @prebuild}), ctx)

      assert File.read!(VM.paths(ctx.config, @env).data) == "prebuilt disk"
      # Kept for the next environment.
      assert File.read!(VM.Prebuild.disk(ctx.config, @prebuild)) == "prebuilt disk"
      assert_received {:log, "info", "Starting from a prebuild\n"}
      assert_received {:adopt, @env, stage}
      refute File.exists?(stage)
      assert_receive {:guest, "env.create", %{prebuild_id: @prebuild}}
    end

    test "startup stops an interrupted initializer before reclaiming its unpublished disk", ctx do
      nonce = String.duplicate("a", 32)
      stage = Path.join(ctx.config.vm_root, ".adopt-" <> nonce)
      File.mkdir_p!(stage)
      File.write!(Path.join(stage, "data.raw"), "abandoned clone")

      seed =
        Path.join(
          ctx.config.vm_root,
          ".disk-" <> Base.url_encode64(:crypto.strong_rand_bytes(16)) <> ".seed"
        )

      File.mkdir!(seed)
      File.write!(Path.join(seed, ".env-id"), @env)
      :ok = VM.Env.recover(ctx.config)
      assert_received {:machine, :stop_adoption, ^nonce}
      refute File.exists?(stage <> ".discard")
      refute File.exists?(stage)
      refute File.exists?(seed)
    end

    test "failed adoption leaves the source intact and publishes no data disk", ctx do
      prebuilt(ctx.config, "prebuilt disk")
      FakeMachine.configure(test: self(), adopt: {:error, "interrupted adoption"})

      assert {:error, "interrupted adoption"} = run(create(%{prebuild_id: @prebuild}), ctx)
      refute File.exists?(VM.paths(ctx.config, @env).data)
      assert File.read!(VM.Prebuild.disk(ctx.config, @prebuild)) == "prebuilt disk"
      assert_received {:adopt, @env, stage}
      refute File.exists?(stage)
    end

    test "one the box doesn't have starts from an empty disk", ctx do
      assert {:ok, _} = run(create(%{prebuild_id: @prebuild}), ctx)

      assert File.stat!(VM.paths(ctx.config, @env).data).size ==
               ctx.config.vm_disk_gb * 1024 * 1024 * 1024
    end

    test "the VM one is built in isn't an environment, and box.gc removes one nothing is building",
         ctx do
      {:ok, _} = run(create(), ctx)
      paths = VM.paths(ctx.config, @prebuild)
      File.mkdir_p!(paths.dir)

      VM.write_meta(ctx.config, @prebuild, %{
        "slug" => "prebuild-3c2b1a09",
        "kind" => "prebuild",
        "op_id" => ForemanProtocol.uuid()
      })

      assert VM.list(ctx.config) == [@env]
      assert Enum.sort(VM.list(ctx.config, :all)) == Enum.sort([@env, @prebuild])
      assert {:ok, [%{env_id: @env}]} = Status.inventory(ctx.config)

      assert {:ok, _} = Status.gc(ctx.ctx)
      refute File.exists?(paths.dir)
      assert File.exists?(VM.paths(ctx.config, @env).dir)
    end

    test "a build whose VM had to be forced off isn't kept", ctx do
      FakeMachine.configure(
        test: self(),
        power_off: :killed,
        handler: fn cmd, _log -> {:ok, %{"ran" => cmd.type}} end
      )

      assert {:error, message} = handle(prebuild_command())
      assert message =~ "didn't shut down"
      refute VM.Prebuild.exists?(ctx.config, @prebuild)
      refute File.exists?(VM.paths(ctx.config, @prebuild).dir)
    end

    test "a build that breaks partway still gives back its VM", ctx do
      # Nowhere to keep the disk.
      File.write!(ctx.config.prebuilds_root, "not a directory")
      assert {:error, _} = handle(prebuild_command())
      assert_received {:machine, :release, @prebuild}
      refute File.exists?(VM.paths(ctx.config, @prebuild).dir)
    end

    test "a build the guest never finishes is given up, and its VM given back", ctx do
      hangs_on("env.create")
      assert {:error, message} = handle(prebuild_command())
      assert message =~ "didn't finish it in time"
      refute File.exists?(VM.paths(ctx.config, @prebuild).dir)
      assert_received {:machine, :release, @prebuild}
    end

    test "builds in a VM the size of the repo's environments", ctx do
      assert {:ok, _} = handle(prebuild_command(%{limits: %{cpus: 1, memory_mb: 3072}}))
      assert_received {:machine, {:boot, %{memory_mb: 3072}}, @prebuild}
    end

    test "box.gc deletes the prebuilds the control plane doesn't know, and only when it says",
         ctx do
      prebuilt(ctx.config, "kept")
      other = "5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a"
      File.mkdir_p!(VM.Prebuild.dir(ctx.config, other))
      File.write!(VM.Prebuild.disk(ctx.config, other), "forgotten")

      assert {:ok, _} = Status.gc(ctx.ctx, %{})
      assert VM.Prebuild.exists?(ctx.config, other)

      assert {:ok, _} = Status.gc(ctx.ctx, %{prebuilds: [@prebuild]})
      assert VM.Prebuild.exists?(ctx.config, @prebuild)
      refute File.exists?(VM.Prebuild.dir(ctx.config, other))
    end

    test "at the agent's start, prebuild VMs nothing is building any more go", ctx do
      paths = VM.paths(ctx.config, @prebuild)
      File.mkdir_p!(paths.dir)
      VM.write_meta(ctx.config, @prebuild, %{"slug" => "prebuild-3c2b1a09", "kind" => "prebuild"})

      :ok = VM.Env.recover(ctx.config)
      refute File.exists?(paths.dir)
      assert_received {:machine, :release, @prebuild}
    end

    test "box.prebuild.delete removes it", ctx do
      prebuilt(ctx.config, "prebuilt disk")
      {:ok, cmd} = Command.new("box.prebuild.delete", %{prebuild_id: @prebuild})
      assert {:ok, %{}} = handle(cmd)
      refute File.exists?(VM.Prebuild.dir(ctx.config, @prebuild))
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
