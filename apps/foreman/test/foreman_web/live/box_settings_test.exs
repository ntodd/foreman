defmodule ForemanWeb.BoxSettingsTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Boxes, Scope}

  describe "an admin editing the box's settings" do
    setup :register_and_log_in_admin

    test "a validation error outlasts the box's next stats", %{conn: conn, user: user} do
      box = box_fixture(owner_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      html =
        view |> form("#box-settings", box: %{contention_threshold: "9"}) |> render_submit()

      assert html =~ "less than or equal to 4"

      # Every box sends stats every 30 seconds.
      send(view.pid, {:box_stats, box.id})
      assert render(view) =~ "less than or equal to 4"

      send(view.pid, {:box, :updated, box.id})
      assert render(view) =~ "less than or equal to 4"
    end

    test "someone else's save still shows", %{conn: conn, user: user} do
      box = box_fixture(owner_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      {:ok, _} =
        Boxes.update_box(Scope.for_user(user), Boxes.get_box!(box.id), %{
          "name" => box.name,
          "contention_threshold" => "0.5"
        })

      assert view |> element("#box-settings input[name='box[contention_threshold]']") |> render() =~
               ~s(value="0.5")
    end
  end

  describe "someone the box is shared with" do
    setup :register_and_log_in

    test "is sent away when it's unshared", %{conn: conn, user: user} do
      admin = user_fixture(role: "admin")
      box = box_fixture(owner_user_id: admin.id, shared_user_ids: [user.id])
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      {:ok, _} =
        Boxes.update_box(Scope.for_user(admin), Boxes.get_box!(box.id), %{
          "name" => box.name,
          "shared_user_ids" => []
        })

      assert_redirect(view, ~p"/boxes")
    end
  end
end
