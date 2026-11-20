defmodule ForemanWeb.BoxSettingsTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Boxes, Scope}

  describe "an admin editing the box's settings" do
    setup :register_and_log_in_admin

    test "a validation error outlasts the box's next stats", %{conn: conn, user: user} do
      box = box_fixture(owner_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      html =
        view |> form("#box-settings", box: %{memory_threshold: "9"}) |> render_submit()

      assert html =~ "less than or equal to 4"

      # Every box sends stats every 30 seconds.
      send(view.pid, {:box_stats, box.id})
      assert render(view) =~ "less than or equal to 4"

      send(view.pid, {:box, :updated, box.id})
      assert render(view) =~ "less than or equal to 4"
    end

    test "CPU and memory have their own thresholds", %{conn: conn, user: user} do
      box = box_fixture(owner_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      html = view |> form("#box-settings", box: %{cpu_threshold: "17"}) |> render_submit()
      assert html =~ "less than or equal to 16"

      view
      |> form("#box-settings", box: %{cpu_threshold: "4", memory_threshold: "1.2"})
      |> render_submit()

      box = Boxes.get_box!(box.id)
      assert box.cpu_threshold == 4.0
      assert box.memory_threshold == 1.2
    end

    test "someone else's save still shows", %{conn: conn, user: user} do
      box = box_fixture(owner_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

      {:ok, _} =
        Boxes.update_box(Scope.for_user(user), Boxes.get_box!(box.id), %{
          "name" => box.name,
          "cpu_threshold" => "4",
          "memory_threshold" => "0.5"
        })

      assert view |> element("#box-settings input[name='box[cpu_threshold]']") |> render() =~
               ~s(value="4.0")

      assert view |> element("#box-settings input[name='box[memory_threshold]']") |> render() =~
               ~s(value="0.5")
    end
  end

  describe "someone the box is shared with" do
    setup :register_and_log_in

    test "sees their own rows and history, including past environments", %{conn: conn, user: user} do
      owner = user_fixture(role: "admin")
      box = box_fixture(owner_user_id: owner.id, shared_user_ids: [user.id])
      mine = environment_fixture(user: user, box: box)
      retired = environment_fixture(user: user, box: box, destroyed_at: DateTime.utc_now())
      other = environment_fixture(user: owner, box: box)
      orphan = %{id: Ecto.UUID.generate(), slug: "unclaimed-workspace"}

      inventory =
        for env <- [mine, other, orphan], do: %{env_id: env.id, slug: env.slug, state: "running"}

      Foreman.Environments.reconcile_inventory(box.id, inventory)
      on_exit(fn -> :persistent_term.erase({Foreman.Environments, :orphans, box.id}) end)

      usage =
        Map.new(
          [mine, retired, other, orphan],
          &{&1.id, %{slug: &1.slug, cpu_percent: 10, memory_mb: 256}}
        )

      Foreman.Metrics.record_envs(box.id, usage)

      {:ok, view, html} = live(conn, ~p"/boxes/#{box.id}")
      assert has_element?(view, "a[href='/environments/#{mine.id}']")
      assert has_element?(view, "#cpu-chart li", mine.slug)
      assert has_element?(view, "#memory-chart li", retired.slug)
      refute html =~ other.slug
      refute html =~ orphan.slug

      {:ok, admin_view, _html} = conn |> log_in(owner) |> live(~p"/boxes/#{box.id}")
      assert has_element?(admin_view, "#cpu-chart li", other.slug)
      assert has_element?(admin_view, "#orphans", orphan.slug)
    end

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
