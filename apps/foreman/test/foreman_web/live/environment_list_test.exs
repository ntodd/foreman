defmodule ForemanWeb.EnvironmentListTest do
  # The home page's environment list: yours apart from everyone else's,
  # filters by state and box, and only as much of that as there's data for.
  use ForemanWeb.ConnCase

  describe "one person, one box" do
    setup :register_and_log_in

    setup %{user: user} do
      box = box_fixture(owner_user_id: user.id, name: "desktop")
      running = environment_fixture(user: user, box: box, slug: "api-1")

      stopped =
        environment_fixture(
          user: user,
          box: box,
          slug: "docs-1",
          desired_state: "stopped",
          observed_state: "stopped"
        )

      %{box: box, running: running, stopped: stopped}
    end

    test "is a flat list with no sections or box filter", %{conn: conn, running: r, stopped: s} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#env-#{r.id}", "api-1")
      assert has_element?(view, "#env-#{s.id}", "docs-1")
      refute has_element?(view, "#my-environments-heading")
      refute has_element?(view, "#other-environments")
      refute has_element?(view, "#box-filter")
      # Every row would be yours.
      refute has_element?(view, "[data-role=owner]")
    end

    test "still filters by state, with counts", %{conn: conn, running: r, stopped: s} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#state-filter [data-state=all]", "2")
      assert has_element?(view, "#state-filter [data-state=running]", "1")
      assert has_element?(view, "#state-filter [data-state=stopped]", "1")
      # Nothing's busy or broken, so those aren't offered.
      refute has_element?(view, "#state-filter [data-state=busy]")
      refute has_element?(view, "#state-filter [data-state=attention]")

      view |> element("#state-filter [data-state=stopped]") |> render_click()
      assert_patch(view, ~p"/?state=stopped")

      assert has_element?(view, "#env-#{s.id}")
      refute has_element?(view, "#env-#{r.id}")
    end

    test "groups error, missing and partly running as needing attention", %{
      conn: conn,
      user: user,
      box: box,
      running: r
    } do
      broken = environment_fixture(user: user, box: box, observed_state: "error")
      partial = environment_fixture(user: user, box: box, observed_state: "partial")
      busy = environment_fixture(user: user, box: box, observed_state: "creating")

      {:ok, view, _html} = live(conn, ~p"/?state=attention")

      assert has_element?(view, "#state-filter [data-state=attention]", "2")
      assert has_element?(view, "#state-filter [data-state=busy]", "1")
      assert has_element?(view, "#env-#{broken.id}")
      assert has_element?(view, "#env-#{partial.id}")
      refute has_element?(view, "#env-#{busy.id}")
      refute has_element?(view, "#env-#{r.id}")
    end

    test "says so when nothing matches, with a way back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?state=busy")

      assert has_element?(view, "#no-matches")
      view |> element("#no-matches a", "Show all") |> render_click()
      assert_patch(view, ~p"/")
    end

    test "retries a first create that failed", %{conn: conn, user: user, box: box} do
      failed =
        environment_fixture(user: user, box: box, observed_state: "error", created_once: false)

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#env-#{failed.id} button", "Retry") |> render_click()

      assert [%{action: "create"} | _] = Foreman.Operations.list_for_environment(failed.id)
    end

    test "ignores a state it doesn't know", %{conn: conn, running: r, stopped: s} do
      {:ok, view, _html} = live(conn, ~p"/?state=bogus")

      assert has_element?(view, "#env-#{r.id}")
      assert has_element?(view, "#env-#{s.id}")
    end
  end

  describe "an admin who can see other people's" do
    setup :register_and_log_in_admin

    setup %{user: user} do
      other = user_fixture(login: "jordan")
      desktop = box_fixture(owner_user_id: user.id, name: "desktop")
      rack = box_fixture(owner_user_id: other.id, name: "rack")
      mine = environment_fixture(user: user, box: desktop, slug: "api-1")
      theirs = environment_fixture(user: other, box: rack, slug: "api-2")
      %{other: other, desktop: desktop, rack: rack, mine: mine, theirs: theirs}
    end

    test "puts theirs under Others, with the owner on each row", %{
      conn: conn,
      user: user,
      mine: mine,
      theirs: theirs
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#my-environments #env-#{mine.id}")
      assert has_element?(view, "#other-environments #env-#{theirs.id}")
      refute has_element?(view, "#my-environments #env-#{theirs.id}")
      assert has_element?(view, "#env-#{theirs.id} [data-role=owner][title=jordan]")
      assert has_element?(view, "#env-#{mine.id} [data-role=owner][title=#{user.login}]")
    end

    test "filters by box when there's more than one", %{
      conn: conn,
      rack: rack,
      mine: mine,
      theirs: theirs
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#box-filter")

      view |> form("#box-filter", %{box: rack.id}) |> render_change()
      assert_patch(view, ~p"/?box=#{rack.id}")

      assert has_element?(view, "#env-#{theirs.id}")
      refute has_element?(view, "#env-#{mine.id}")
      # Only Others has anything left.
      refute has_element?(view, "#my-environments")
    end

    test "box and state filters combine", %{conn: conn, desktop: desktop, user: user, mine: mine} do
      stopped =
        environment_fixture(
          user: user,
          box: desktop,
          desired_state: "stopped",
          observed_state: "stopped"
        )

      {:ok, view, _html} = live(conn, ~p"/?box=#{desktop.id}&state=stopped")

      assert has_element?(view, "#env-#{stopped.id}")

      assert view |> element("#state-filter [data-state=stopped]") |> render() =~
               ~s(aria-current="true")

      refute has_element?(view, "#env-#{mine.id}")
    end
  end
end
