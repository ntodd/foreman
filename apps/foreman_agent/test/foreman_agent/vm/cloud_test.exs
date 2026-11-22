defmodule ForemanAgent.VM.Machine.CloudTest do
  # Restoring a VM from its snapshot, as far as the agent goes: it checks
  # the config Cloud Hypervisor saved before it asks the helper.
  use ExUnit.Case, async: true

  alias ForemanAgent.Test.FakeVmctl
  alias ForemanAgent.VM.Machine.Cloud

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @guest "5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592"
  @vm %{cpus: 2, memory_mb: 3072, guest: @guest, agent_version: "0.6.0"}
  @fixture Path.expand("../../fixtures/vm/snapshot-config.json", __DIR__)

  setup do
    # Unix socket paths are short on macOS; System.tmp_dir/0 is long there.
    root = Path.join("/tmp", "fmc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    snapshot = Path.join([root, "vms", @env, "snapshot"])
    File.mkdir_p!(snapshot)

    config =
      FakeVmctl.start(Path.join(root, "vmctl.sock"), %{
        "tap" => "ok fm-vm0",
        "restore" => "ok restored fm-vm0 10.250.0.2"
      })

    config = %{
      config
      | vm_root: Path.join(root, "vms"),
        guest_root: Path.join(root, "guest"),
        agent_disks: Path.join(root, "agent-disks")
    }

    # The fixture's config, as saved for a VM under this root.
    saved = @fixture |> File.read!() |> String.replace("/srv/foreman/", root <> "/")
    %{config: config, config_json: Path.join(snapshot, "config.json"), saved: saved}
  end

  test "a pinned management endpoint survives removal of its VM directory entry", ctx do
    source = ForemanAgent.VM.paths(ctx.config, @env).api
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, source}, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)

    assert {:ok, pin} = ForemanAgent.VM.pin_socket(ctx.config, @env, :api)
    refute String.starts_with?(pin, Path.dirname(source) <> "/")
    assert {:ok, ^pin} = ForemanAgent.VM.pin_socket(ctx.config, @env, :api)

    File.rm!(source)
    assert {:ok, client} = :gen_tcp.connect({:local, pin}, 0, [:binary], 500)
    :gen_tcp.close(client)
    File.write!(source, "ordinary file")
    assert {:error, _} = ForemanAgent.VM.pin_socket(ctx.config, @env, :api)
  end

  test "snapshot scratch directories are private at creation", ctx do
    path = Path.join(Path.dirname(ctx.config_json), "scratch")
    assert :ok = ForemanAgent.VM.mkdir_private(path)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700
    assert {:error, _} = ForemanAgent.VM.mkdir_private(path)
  end

  test "asks the helper to restore a VM whose snapshot is the one start gave it", ctx do
    File.write!(ctx.config_json, ctx.saved)
    assert Cloud.restore(@env, @vm, ctx.config) == :ok
    assert_received {:vmctl, "tap " <> @env}
    assert_received {:vmctl, "restore " <> @env <> " 2 3072"}
  end

  test "won't restore a VM whose snapshot turns Landlock off", ctx do
    File.write!(
      ctx.config_json,
      String.replace(ctx.saved, ~S("landlock_enable": true), ~S("landlock_enable": false))
    )

    assert Cloud.restore(@env, @vm, ctx.config) ==
             {:error,
              "couldn't resume the environment's VM: the snapshot's config turns Landlock off"}

    refute_received {:vmctl, "restore " <> _}
  end

  test "won't restore a VM onto a tap the helper didn't give it", ctx do
    File.write!(ctx.config_json, String.replace(ctx.saved, "fm-vm0", "fm-vm3"))
    assert {:error, message} = Cloud.restore(@env, @vm, ctx.config)
    assert message =~ "network"
    refute_received {:vmctl, "restore " <> _}
  end

  test "won't restore a VM from a snapshot of another agent disk", ctx do
    File.write!(ctx.config_json, ctx.saved)
    assert {:error, message} = Cloud.restore(@env, %{@vm | agent_version: "0.6.1"}, ctx.config)
    assert message =~ "the snapshot's config"
    refute_received {:vmctl, "restore " <> _}
  end
end
