defmodule Foreman.BoxesRestartTest do
  @moduledoc """
  Rebooting a box from Foreman (box.restart, protocol 5). The agent says
  whether it can (the install script set up the root unit that does it)
  and which boot it's on; the command names that boot, and the box coming
  back on another one is what finishes it.
  """
  use ForemanWeb.ChannelCase

  alias Foreman.{Agents, Boxes, Operations, Repo, Scope}
  alias ForemanProtocol.Event
  alias ForemanWeb.AgentSocket

  @boot "0b5a1f0e-7d1c-4c5e-9a43-5f1e2d3c4b5a"
  @next_boot "9f1e2d3c-4b5a-4c5e-9a43-0b5a1f0e7d1c"

  setup do
    owner = user_fixture()
    admin = Scope.for_user(user_fixture(role: "admin"))
    box = box_fixture(owner_user_id: owner.id, name: "desk")
    %{admin: admin, owner: Scope.for_user(owner), box: box}
  end

  defp join_box(box) do
    {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
    {:ok, _, socket} = subscribe_and_join(socket, "agent:#{box.id}", join_payload())
    socket
  end

  defp send_event(socket, type, payload) do
    {:ok, event} = Event.new(type, payload)
    ref = push(socket, "event", Event.to_wire(event))
    assert_reply ref, :ok
  end

  defp reboot_report(boot_id, can_restart \\ true),
    do: %{
      required: true,
      packages: ["flatcar-4757.2.4"],
      can_restart: can_restart,
      boot_id: boot_id
    }

  test "records whether the agent can reboot the box, and its boot", %{box: box} do
    :ok = Boxes.record_reboot(box.id, reboot_report(@boot))
    box = Repo.reload!(box)
    assert box.can_restart
    assert box.boot_id == @boot
  end

  test "an agent before protocol 5 can't, and says no boot", %{box: box} do
    :ok = Boxes.record_reboot(box.id, %{required: true, packages: [], livepatch: false})
    box = Repo.reload!(box)
    refute box.can_restart
    assert box.boot_id == nil
  end

  test "sends the reboot for the boot the box is on", %{admin: admin, box: box} do
    socket = join_box(box)
    send_event(socket, "box.reboot", reboot_report(@boot))

    {:ok, op} = Agents.run_box_command(admin, Boxes.get_box!(box.id), "box.restart")
    assert op.action == "box.restart"
    assert op.args == %{"boot_id" => @boot}
    assert_push "command", %{"type" => "box.restart", "payload" => %{"boot_id" => @boot}}
  end

  test "the box coming back on another boot finishes it, answered or not", %{
    admin: admin,
    box: box
  } do
    socket = join_box(box)
    send_event(socket, "box.reboot", reboot_report(@boot))
    {:ok, op} = Agents.run_box_command(admin, Boxes.get_box!(box.id), "box.restart")

    # The same boot again (a reconnect before the reboot) leaves it be.
    send_event(socket, "box.reboot", reboot_report(@boot))
    assert Operations.get!(op.id).status == "dispatched"

    send_event(socket, "box.reboot", reboot_report(@next_boot))
    assert %{status: "succeeded", finished_at: %DateTime{}} = Operations.get!(op.id)
  end

  # The page's copy of the box can be a boot behind: the command names
  # the boot the agent last reported, or it would do nothing.
  test "names the latest boot, not the caller's stale copy of the box", %{admin: admin, box: box} do
    socket = join_box(box)
    send_event(socket, "box.reboot", reboot_report(@boot))
    stale = Boxes.get_box!(box.id)
    send_event(socket, "box.reboot", reboot_report(@next_boot))

    {:ok, _op} = Agents.run_box_command(admin, stale, "box.restart")
    assert_push "command", %{"type" => "box.restart", "payload" => %{"boot_id" => @next_boot}}
  end

  test "isn't offered for a box whose agent can't", %{admin: admin, box: box} do
    _socket = join_box(box)
    :ok = Boxes.record_reboot(box.id, reboot_report(@boot, false))

    assert {:error, :cannot_restart} =
             Agents.run_box_command(admin, Boxes.get_box!(box.id), "box.restart")

    refute_push "command", %{"type" => "box.restart"}
  end

  test "is an admin's to do", %{owner: owner, box: box} do
    :ok = Boxes.record_reboot(box.id, reboot_report(@boot))

    assert {:error, :unauthorized} =
             Agents.run_box_command(owner, Boxes.get_box!(box.id), "box.restart")
  end
end
