defmodule ForemanWeb.EnvironmentRebuildMenuTest do
  # Rebuild is a menu: rebuild as the clone is, or pull first.
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

    assert has_element?(view, "#rebuild-menu [role=menuitem]", "Rebuild")
    assert has_element?(view, "#rebuild-menu [role=menuitem]", "Keeps the clone as it is")
    assert has_element?(view, "#rebuild-menu [role=menuitem]", "Pull and rebuild")
    assert has_element?(view, "#rebuild-menu [role=menuitem]", "origin/feature/x")
  end

  test "pull and rebuild", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("#rebuild-menu [role=menuitem]", "Pull and rebuild") |> render_click()

    assert [%{action: "pull_rebuild"} | _] = Operations.list_for_environment(env.id)
  end

  test "plain rebuild", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("#rebuild-menu [role=menuitem][phx-value-do=rebuild]") |> render_click()

    assert [%{action: "rebuild"} | _] = Operations.list_for_environment(env.id)
  end

  test "an older agent can't pull", %{conn: conn, env: env, box: box} do
    box |> Ecto.Changeset.change(protocol_version: 2) |> Foreman.Repo.update!()
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert view |> element("#rebuild-menu [phx-value-do=pull_rebuild]") |> render() =~ "disabled"
    assert has_element?(view, "#rebuild-menu", "desktop needs a newer agent")
  end
end
