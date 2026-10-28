defmodule ForemanWeb.EnvironmentRestartTest do
  # Restart is a stop and a start in one click.
  use ForemanWeb.ConnCase

  alias Foreman.Operations

  setup :register_and_log_in

  test "a running environment can be restarted", %{conn: conn, user: user} do
    env = environment_fixture(user: user)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    view |> element("#env-restart") |> render_click()

    assert [%{action: "restart_all"} | _] = Operations.list_for_environment(env.id)
  end

  test "a partly running one can be restarted too", %{conn: conn, user: user} do
    env = environment_fixture(user: user, observed_state: "partial")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#env-restart")
  end

  test "a stopped one offers Start, not Restart", %{conn: conn, user: user} do
    env = environment_fixture(user: user, desired_state: "stopped", observed_state: "stopped")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    refute has_element?(view, "#env-restart")
  end
end
