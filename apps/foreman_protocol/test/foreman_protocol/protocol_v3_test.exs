defmodule ForemanProtocol.ProtocolV3Test do
  @moduledoc """
  Protocol 3: an agent says when it joins how its box isolates
  environments, as containers on the box's own Docker or each in its own
  VM. The agent decides, so a control plane can't talk a box out of it.
  """
  use ExUnit.Case, async: true

  @join %{
    "agent_version" => "0.1.0",
    "protocol_version" => 3,
    "hostname" => "box-a",
    "os" => "linux",
    "arch" => "x86_64"
  }

  # Protocol 3 only adds to the join, and older agents get its default.
  # So it still takes agents on 1 (v0.2.0): refusing them at join would
  # leave no way to send them an update.
  test "this build speaks protocol 3 and still accepts agents on 2 and 1" do
    assert ForemanProtocol.version() == 3
    assert ForemanProtocol.compatible?(3)
    assert ForemanProtocol.compatible?(2)
    assert ForemanProtocol.compatible?(1)
    refute ForemanProtocol.compatible?(0)
    refute ForemanProtocol.compatible?(4)
  end

  describe "isolation in the join payload" do
    test "a box that runs each environment in its own VM says so" do
      assert {:ok, join} = ForemanProtocol.cast_join(Map.put(@join, "isolation", "vm"))
      assert join.isolation == "vm"
      assert ForemanProtocol.dump_join(join)["isolation"] == "vm"
    end

    test "an agent that doesn't say (protocol 2) runs containers" do
      assert {:ok, %{isolation: "container"}} =
               ForemanProtocol.cast_join(Map.put(@join, "protocol_version", 2))
    end

    test "anything else is refused" do
      for value <- ["kvm", "VM", "", 1] do
        assert {:error, [{"isolation", _}]} =
                 ForemanProtocol.cast_join(Map.put(@join, "isolation", value))
      end
    end
  end
end
