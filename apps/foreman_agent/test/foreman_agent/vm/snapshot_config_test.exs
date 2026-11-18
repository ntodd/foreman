defmodule ForemanAgent.VM.SnapshotConfigTest do
  # The config Cloud Hypervisor saves with a snapshot is in the VM's own
  # directory, which the VM can write. These are the changes a VMM that
  # got out of its guest could make to it before its next resume.
  use ExUnit.Case, async: true

  alias ForemanAgent.VM.SnapshotConfig

  @env "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @other "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"
  @dir "/srv/foreman/vms/#{@env}"
  @guest "/srv/foreman/guest/5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592"
  @agent_disk "/srv/foreman/agent-disks/0.6.0.img"
  @want %{
    dir: @dir,
    guest: @guest,
    agent_disk: @agent_disk,
    tap: "fm-vm0",
    cpus: 2,
    memory_mb: 3072
  }

  @fixture Path.expand("../../fixtures/vm/snapshot-config.json", __DIR__)

  defp saved, do: @fixture |> File.read!() |> JSON.decode!()

  defp check(config), do: SnapshotConfig.check(JSON.encode!(config), @want)

  defp refused(config, why) do
    assert {:error, message} = check(config)
    assert message =~ why
  end

  test "takes the config start gives a VM" do
    assert check(saved()) == :ok
  end

  test "takes optional settings left empty" do
    config = Map.merge(saved(), %{"pmem" => nil, "fs" => [], "devices" => nil, "tpm" => nil})
    assert check(config) == :ok
  end

  describe "Landlock" do
    test "turned off" do
      refused(%{saved() | "landlock_enable" => false}, "turns Landlock off")
      refused(Map.delete(saved(), "landlock_enable"), "turns Landlock off")
    end

    test "turned off with a key the JSON escapes" do
      json =
        saved()
        |> Map.delete("landlock_enable")
        |> JSON.encode!()
        |> String.replace_prefix("{", ~S({"landlock_\u0065nable":false,))

      assert {:error, message} = SnapshotConfig.check(json, @want)
      assert message =~ "turns Landlock off"
    end

    test "with a rule start doesn't give" do
      rules = saved()["landlock_rules"] ++ [%{"path" => "/", "access" => "rw"}]
      refused(%{saved() | "landlock_rules" => rules}, "Landlock rules")
    end

    test "with a rule widened" do
      rules =
        Enum.map(saved()["landlock_rules"], fn
          %{"path" => @agent_disk} = rule -> %{rule | "access" => "rw"}
          rule -> rule
        end)

      refused(%{saved() | "landlock_rules" => rules}, "Landlock rules")
    end

    test "with a rule for another tap" do
      rules =
        Enum.map(saved()["landlock_rules"], fn
          %{"path" => "/sys/devices/virtual/net/" <> _} = rule ->
            %{rule | "path" => "/sys/devices/virtual/net/fm-vm7"}

          rule ->
            rule
        end)

      refused(%{saved() | "landlock_rules" => rules}, "Landlock rules")
    end

    test "with rules that aren't a list" do
      refused(
        %{saved() | "landlock_rules" => %{"path" => "/", "access" => "rw"}},
        "Landlock rules"
      )
    end
  end

  describe "disks" do
    test "another environment's, through the agent's mount namespace" do
      disks =
        Enum.map(saved()["disks"], fn
          %{"path" => @dir <> "/data.raw"} = disk ->
            %{disk | "path" => "/proc/1234/root/srv/foreman/vms/#{@other}/data.raw"}

          disk ->
            disk
        end)

      refused(%{saved() | "disks" => disks}, "disks")
    end

    test "one more" do
      extra = %{"path" => "/var/lib/foreman-agent/identity.json", "readonly" => true}
      refused(%{saved() | "disks" => saved()["disks"] ++ [extra]}, "disks")
    end

    test "one fewer" do
      refused(%{saved() | "disks" => Enum.drop(saved()["disks"], 1)}, "disks")
    end

    test "the agent disk writable" do
      disks =
        Enum.map(saved()["disks"], fn
          %{"path" => @agent_disk} = disk -> %{disk | "readonly" => false}
          disk -> disk
        end)

      refused(%{saved() | "disks" => disks}, "disks")
    end

    # A qcow2 header names its backing file, which Cloud Hypervisor would
    # open before Landlock; the guest writes the disk's contents.
    test "read as another format, which could name a backing file" do
      [first | rest] = saved()["disks"]
      qcow = Map.merge(first, %{"image_type" => "Qcow2", "backing_files" => true})
      refused(%{saved() | "disks" => [qcow | rest]}, "disks")
      refused(%{saved() | "disks" => [Map.put(first, "backing_files", true) | rest]}, "disks")
    end

    test "with its format left for Cloud Hypervisor to guess" do
      [first | rest] = saved()["disks"]
      refused(%{saved() | "disks" => [Map.delete(first, "image_type") | rest]}, "disks")
    end

    test "served over vhost-user" do
      [first | rest] = saved()["disks"]
      disk = Map.merge(first, %{"vhost_user" => true, "vhost_socket" => "/run/foreman/x.sock"})
      refused(%{saved() | "disks" => [disk | rest]}, "disks")
    end
  end

  describe "payload" do
    test "another kernel" do
      payload = %{saved()["payload"] | "kernel" => "/srv/foreman/guest/other/vmlinuz"}
      refused(%{saved() | "payload" => payload}, "kernel")
    end

    test "an initramfs or firmware" do
      for key <- ~w(initramfs firmware igvm) do
        payload = Map.put(saved()["payload"], key, "/var/lib/foreman-agent/identity.json")
        refused(%{saved() | "payload" => payload}, "kernel")
      end
    end
  end

  describe "network" do
    test "a tap that isn't one of the box's VM taps" do
      [net] = saved()["net"]
      refused(%{saved() | "net" => [%{net | "tap" => "eth0"}]}, "network")
    end

    test "another environment's tap, with rules to match" do
      [net] = saved()["net"]

      rules =
        Enum.map(saved()["landlock_rules"], fn
          %{"path" => "/sys/devices/virtual/net/" <> _} = rule ->
            %{rule | "path" => "/sys/devices/virtual/net/fm-vm7"}

          rule ->
            rule
        end)

      refused(
        %{saved() | "net" => [%{net | "tap" => "fm-vm7"}], "landlock_rules" => rules},
        "network"
      )
    end

    test "two taps" do
      [net] = saved()["net"]
      refused(%{saved() | "net" => [net, %{net | "tap" => "fm-vm7"}]}, "network")
    end

    test "vhost-user, or file descriptors" do
      [net] = saved()["net"]
      vhost = Map.merge(net, %{"vhost_user" => true, "vhost_socket" => "/run/x.sock"})
      refused(%{saved() | "net" => [vhost]}, "network")
      refused(%{saved() | "net" => [Map.put(net, "fds", [3])]}, "network")
    end
  end

  describe "files it opens" do
    test "randomness from somewhere else" do
      refused(
        put_in(saved(), ["rng", "src"], "/var/lib/foreman-agent/identity.json"),
        "randomness"
      )
    end

    test "the serial console to another file, or a socket" do
      refused(
        put_in(saved(), ["serial", "file"], "/opt/foreman-agent/current/bin/foreman_agent"),
        "console"
      )

      refused(
        %{saved() | "serial" => %{"mode" => "Socket", "socket" => @dir <> "/s.sock"}},
        "console"
      )
    end

    test "the virtio console or the debug console to a file" do
      refused(
        %{saved() | "console" => %{"mode" => "File", "file" => @dir <> "/c.log"}},
        "console"
      )

      refused(
        %{saved() | "debug_console" => %{"mode" => "File", "file" => @dir <> "/d.log"}},
        "console"
      )
    end

    test "the vsock socket somewhere else" do
      refused(put_in(saved(), ["vsock", "socket"], "/run/foreman-vmctl.sock"), "vsock")
    end

    test "a snapshot must match the recorded CPU and memory allocation" do
      refused(put_in(saved(), ["cpus", "boot_vcpus"], 1), "CPU allocation")
      refused(put_in(saved(), ["cpus", "max_vcpus"], 3), "CPU allocation")
      refused(put_in(saved(), ["memory", "size"], 1024), "memory allocation")
    end

    test "memory from a file" do
      zone = %{
        "id" => "z",
        "size" => 1024,
        "file" => "/proc/1234/root/srv/foreman/vms/#{@other}/snapshot/memory-ranges"
      }

      refused(put_in(saved(), ["memory", "zones"], [zone]), "memory")
    end
  end

  test "devices start doesn't give a VM, known to Cloud Hypervisor or not" do
    for {key, value} <- [
          {"pmem", [%{"file" => "/var/lib/foreman-agent/identity.json"}]},
          {"fs", [%{"tag" => "x", "socket" => "/run/x.sock"}]},
          {"devices", [%{"path" => "/sys/bus/pci/devices/0000:00:01.0"}]},
          {"user_devices", [%{"socket" => "/run/x.sock"}]},
          {"vdpa", [%{"path" => "/dev/vhost-vdpa-0"}]},
          {"tpm", %{"socket" => "/run/x.sock"}},
          {"generic_vhost_user", [%{"socket" => "/run/x.sock"}]},
          {"ivshmem", %{"path" => "/dev/shm/x"}},
          {"some_later_device", %{"path" => "/x"}}
        ] do
      refused(Map.put(saved(), key, value), key)
    end
  end

  test "anything that isn't the JSON Cloud Hypervisor writes" do
    for json <- ["", "[]", "null", "{", ~S({"landlock_enable": true})] do
      assert {:error, _} = SnapshotConfig.check(json, @want)
    end
  end

  describe "check_file/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "fm-snap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "reads the snapshot's config", ctx do
      path = Path.join(ctx.dir, "config.json")
      File.cp!(@fixture, path)
      assert SnapshotConfig.check_file(path, @want) == :ok
    end

    test "won't follow a symlink", ctx do
      path = Path.join(ctx.dir, "config.json")
      File.ln_s!(@fixture, path)
      assert {:error, message} = SnapshotConfig.check_file(path, @want)
      assert message =~ "isn't a plain file"
    end
  end
end
