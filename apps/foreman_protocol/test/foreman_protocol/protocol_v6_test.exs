defmodule ForemanProtocol.ProtocolV6Test do
  @moduledoc """
  Protocol 6: every environment runs in a VM of its own. The join says
  whether the box can run them. Agents on protocol 5 ran environments on
  the box's shared Docker, which this protocol removed, so they're
  refused rather than accepted as the protocol before this one.
  """
  use ExUnit.Case, async: true

  @join %{
    "agent_version" => "0.5.0",
    "protocol_version" => 6,
    "hostname" => "box",
    "os" => "linux",
    "arch" => "linux-amd64"
  }

  test "this build speaks protocol 8 and accepts VM agents back to 6" do
    assert ForemanProtocol.version() == 8
    assert ForemanProtocol.oldest() == 6
    assert ForemanProtocol.compatible?(6)
    refute ForemanProtocol.compatible?(5)
    assert ForemanProtocol.compatible?(7)
    assert ForemanProtocol.compatible?(8)
    refute ForemanProtocol.compatible?(9)
    refute ForemanProtocol.compatible?("6")
  end

  test "the join reports whether the box can run environment VMs" do
    assert {:ok, join} =
             ForemanProtocol.cast_join(
               Map.put(@join, "vm", %{"ready" => true, "nested" => true, "reflink" => false})
             )

    assert join.vm == %{ready: true, nested: true, reflink: false}
  end

  test "and why it can't" do
    vm = %{"ready" => false, "reason" => "this box has no /dev/kvm"}
    assert {:ok, join} = ForemanProtocol.cast_join(Map.put(@join, "vm", vm))
    assert join.vm.reason == "this box has no /dev/kvm"
    assert {:error, _} = ForemanProtocol.cast_join(Map.put(@join, "vm", %{"reason" => "x"}))
  end

  test "env.suspend names the environment, and an environment can be reported suspended" do
    env_id = ForemanProtocol.uuid()

    assert {:ok, cmd} =
             ForemanProtocol.Command.new("env.suspend", %{env_id: env_id, slug: "hello-1"})

    assert cmd.payload == %{env_id: env_id, slug: "hello-1"}

    assert {:ok, _} =
             ForemanProtocol.Event.new("env.state", %{env_id: env_id, state: "suspended"})
  end

  test "box.prebuild names the repo, branch and config, and env.create can start from one" do
    prebuild = ForemanProtocol.uuid()

    assert {:ok, cmd} =
             ForemanProtocol.Command.new("box.prebuild", %{
               prebuild_id: prebuild,
               repo: "acme/hello",
               clone_url: "https://github.com/acme/hello.git",
               branch: "main",
               files: %{"github-token" => "ghs_x"}
             })

    assert cmd.payload.config_path == ".devcontainer/devcontainer.json"
    assert {:error, _} = ForemanProtocol.Command.new("box.prebuild", %{prebuild_id: prebuild})
    assert {:ok, _} = ForemanProtocol.Command.new("box.prebuild.delete", %{prebuild_id: prebuild})

    assert {:ok, create} =
             ForemanProtocol.Command.new("env.create", %{
               env_id: ForemanProtocol.uuid(),
               slug: "hello-1",
               repo: "acme/hello",
               clone_url: "https://github.com/acme/hello.git",
               branch: "main",
               prebuild_id: prebuild
             })

    assert create.payload.prebuild_id == prebuild
    refute Map.has_key?(create.payload, :prebuild)
  end

  test "box.gc can name the prebuilds to keep, and box.prebuild the repo's limits" do
    prebuild = ForemanProtocol.uuid()
    assert {:ok, gc} = ForemanProtocol.Command.new("box.gc", %{prebuilds: [prebuild]})
    assert gc.payload.prebuilds == [prebuild]
    assert {:ok, plain} = ForemanProtocol.Command.new("box.gc", %{})
    refute Map.has_key?(plain.payload, :prebuilds)
    assert {:error, _} = ForemanProtocol.Command.new("box.gc", %{prebuilds: ["../x"]})

    assert {:ok, cmd} =
             ForemanProtocol.Command.new("box.prebuild", %{
               prebuild_id: prebuild,
               repo: "acme/hello",
               clone_url: "https://github.com/acme/hello.git",
               branch: "main",
               limits: %{cpus: 2, memory_mb: 16_384}
             })

    assert cmd.payload.limits == %{cpus: 2, memory_mb: 16_384}
  end

  test "a join without it is still valid" do
    assert {:ok, join} = ForemanProtocol.cast_join(@join)
    refute Map.has_key?(join, :vm)
  end
end
