defmodule ForemanWeb.BoxRestartLiveTest do
  @moduledoc """
  The box page's Reboot: offered to admins for a box whose agent can
  reboot it (box.restart), beside the reboot alert and with the box's
  other operations.
  """
  use ForemanWeb.ConnCase

  alias ForemanProtocol.Command

  @boot "0b5a1f0e-7d1c-4c5e-9a43-5f1e2d3c4b5a"

  setup :register_and_log_in_admin

  defp online(box), do: {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

  test "reboots a box that needs it, from its alert", %{conn: conn, user: user} do
    box =
      box_fixture(
        owner_user_id: user.id,
        name: "stale",
        reboot_required: true,
        reboot_packages: ["flatcar-4757.2.4"],
        can_restart: true,
        boot_id: @boot
      )

    online(box)
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

    assert has_element?(view, "#box-reboot-alert button", "Reboot now")

    view |> element("#box-reboot-alert button", "Reboot now") |> render_click()

    assert_receive {:dispatch, %Command{type: "box.restart", payload: %{boot_id: @boot}}}
    assert render(view) =~ "Rebooting stale"
  end

  test "recent environment activity leaves the box's own operations visible", context do
    %{conn: conn, user: user} = context
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, box: box)

    Foreman.Operations.create!(%{
      id: Ecto.UUID.generate(),
      box_id: box.id,
      action: "box.gc",
      command: "box.gc",
      status: "failed",
      error: "Prune failed",
      args: %{},
      inserted_at: DateTime.add(DateTime.utc_now(), -60)
    })

    for _ <- 1..10 do
      Foreman.Operations.create!(%{
        id: Ecto.UUID.generate(),
        box_id: box.id,
        environment_id: env.id,
        action: "rebuild",
        command: "env.rebuild",
        status: "succeeded",
        args: %{}
      })
    end

    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
    assert has_element?(view, "#box-operations li", "Prune failed")
    refute has_element?(view, "#box-operations li", "Rebuild")
  end

  test "Reboot is with the box's operations whether or not it needs one", %{
    conn: conn,
    user: user
  } do
    box = box_fixture(owner_user_id: user.id, can_restart: true, boot_id: @boot)
    online(box)
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

    button = element(view, "#box-operations button", "Reboot")
    assert render(button) =~ "data-confirm"
    render_click(button)
    assert_receive {:dispatch, %Command{type: "box.restart"}}
    assert has_element?(view, "#box-operations li", "Reboot")
  end

  test "a box whose agent can't reboot it says how to fix that", %{conn: conn, user: user} do
    box = box_fixture(owner_user_id: user.id, reboot_required: true, can_restart: false)
    online(box)
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

    refute has_element?(view, "button", "Reboot")
    assert has_element?(view, "#box-reboot-alert", "install command")
  end

  test "an offline box can't be rebooted from here", %{conn: conn, user: user} do
    box =
      box_fixture(
        owner_user_id: user.id,
        reboot_required: true,
        can_restart: true,
        boot_id: @boot
      )

    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
    refute has_element?(view, "#box-reboot-alert button", "Reboot now")
    assert has_element?(view, "#box-operations button[disabled]", "Reboot")
  end

  test "a member sees the alert but no Reboot" do
    member = user_fixture()

    box =
      box_fixture(
        owner_user_id: member.id,
        reboot_required: true,
        can_restart: true,
        boot_id: @boot
      )

    online(box)
    {:ok, view, _html} = live(log_in(build_conn(), member), ~p"/boxes/#{box.id}")

    assert has_element?(view, "#box-reboot-alert")
    refute has_element?(view, "button", "Reboot")
  end
end
