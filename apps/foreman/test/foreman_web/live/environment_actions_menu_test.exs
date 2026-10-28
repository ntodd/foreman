defmodule ForemanWeb.EnvironmentActionsMenuTest do
  # Everything but Start/Stop lives in one Actions menu: restart, the two
  # rebuilds, and destroy.
  use ForemanWeb.ConnCase

  alias Foreman.Operations

  setup :register_and_log_in

  setup %{user: user} do
    box = box_fixture(owner_user_id: user.id, name: "desktop")
    box = box |> Ecto.Changeset.change(protocol_version: 3) |> Foreman.Repo.update!()
    env = environment_fixture(user: user, box: box, branch: "feature/x")
    %{env: env, box: box}
  end

  test "offers both rebuilds and says what each does", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#env-actions [role=menuitem]", "Rebuild")
    assert has_element?(view, "#env-actions [role=menuitem]", "Keeps the clone as it is")
    assert has_element?(view, "#env-actions [role=menuitem]", "Pull and rebuild")
    assert has_element?(view, "#env-actions [role=menuitem]", "origin/feature/x")
  end

  test "pull and rebuild", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("#env-actions [role=menuitem]", "Pull and rebuild") |> render_click()

    assert [%{action: "pull_rebuild"} | _] = Operations.list_for_environment(env.id)
  end

  test "plain rebuild", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("#env-actions [role=menuitem][phx-value-do=rebuild]") |> render_click()

    assert [%{action: "rebuild"} | _] = Operations.list_for_environment(env.id)
  end

  test "an older agent can't pull", %{conn: conn, env: env, box: box} do
    box |> Ecto.Changeset.change(protocol_version: 2) |> Foreman.Repo.update!()
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert view |> element("#env-actions [phx-value-do=pull_rebuild]") |> render() =~ "disabled"
    assert has_element?(view, "#env-actions", "desktop needs a newer agent")
  end

  test "restart is a stop and a start in one click", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("#env-actions [role=menuitem][phx-value-do=restart_all]") |> render_click()

    assert [%{action: "restart_all"} | _] = Operations.list_for_environment(env.id)
  end

  test "a partly running environment can be restarted", %{conn: conn, user: user, box: box} do
    env = environment_fixture(user: user, box: box, observed_state: "partial")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#env-actions [phx-value-do=restart_all]")
  end

  test "a stopped one offers Start, not Restart", %{conn: conn, user: user, box: box} do
    env =
      environment_fixture(
        user: user,
        box: box,
        desired_state: "stopped",
        observed_state: "stopped"
      )

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "button[phx-value-do=start]", "Start")
    refute has_element?(view, "button[phx-value-do=stop]")
    refute has_element?(view, "#env-actions [phx-value-do=restart_all]")
  end

  test "Stop is the only action left outside the menu", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "button[phx-value-do=stop]", "Stop")
    refute has_element?(view, "button[phx-click=check_destroy]:not([role=menuitem])")
    refute has_element?(view, "#rebuild-menu")
  end

  test "destroy is in the menu, set apart", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#env-actions [role=separator] + [role=menuitem]", "Destroy")
    view |> element("#env-actions [role=menuitem]", "Destroy") |> render_click()
    assert has_element?(view, "#destroy-modal")
  end
end
