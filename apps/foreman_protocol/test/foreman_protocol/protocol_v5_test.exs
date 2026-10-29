defmodule ForemanProtocol.ProtocolV5Test do
  @moduledoc """
  Protocol 5: `box.restart` reboots the box. The agent says on
  `box.reboot` whether it can (the install script set up the root unit
  that does it) and which boot it's on; the command names that boot, so
  one resent after the reboot doesn't reboot the box again.
  """
  use ExUnit.Case, async: true

  alias ForemanProtocol.{Command, Event}

  @boot_id "0b5a1f0e-7d1c-4c5e-9a43-5f1e2d3c4b5a"

  test "this build speaks protocol 5 and still accepts agents on 4" do
    assert ForemanProtocol.version() == 5
    assert ForemanProtocol.compatible?(5)
    assert ForemanProtocol.compatible?(4)
    refute ForemanProtocol.compatible?(3)
  end

  describe "box.restart" do
    test "names the boot it reboots" do
      assert {:ok, cmd} = Command.new("box.restart", %{"boot_id" => @boot_id})
      assert cmd.payload == %{boot_id: @boot_id}
      assert Command.to_wire(cmd)["payload"] == %{"boot_id" => @boot_id}
    end

    test "needs the boot, so a stale resend can't reboot a box twice" do
      assert {:error, _} = Command.new("box.restart", %{})
      assert {:error, _} = Command.new("box.restart", %{"boot_id" => "not-a-boot"})
    end
  end

  describe "box.reboot" do
    test "says whether Foreman can reboot the box, and which boot it's on" do
      assert {:ok, ev} =
               Event.new("box.reboot", %{
                 "required" => true,
                 "packages" => ["flatcar-4757.2.4"],
                 "can_restart" => true,
                 "boot_id" => @boot_id
               })

      assert %{can_restart: true, boot_id: @boot_id} = ev.payload
    end

    test "an agent without the root unit can't, and the boot is optional" do
      assert {:ok, %{payload: payload}} = Event.new("box.reboot", %{"required" => false})
      assert payload.can_restart == false
      refute Map.has_key?(payload, :boot_id)
    end
  end
end
