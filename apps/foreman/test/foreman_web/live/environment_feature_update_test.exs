defmodule ForemanWeb.EnvironmentFeatureUpdateTest do
  # An environment built with an older Foreman feature than its box ships.
  use ForemanWeb.ConnCase

  alias Foreman.Operations

  setup :register_and_log_in

  setup %{user: user} do
    box = box_fixture(owner_user_id: user.id, name: "desktop", feature_version: "1.1.0")
    %{box: box, user: user}
  end

  test "says which feature it was built with and offers a rebuild", %{
    conn: conn,
    user: user,
    box: box
  } do
    env = environment_fixture(user: user, box: box, feature_version: "1.0.0")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#feature-update", "Foreman feature 1.0.0")
    assert has_element?(view, "#feature-update", "desktop has 1.1.0")

    view |> element("#feature-update button", "Rebuild") |> render_click()
    assert [%{action: "rebuild"} | _] = Operations.list_for_environment(env.id)
  end

  test "an environment with no recorded version may be behind", %{
    conn: conn,
    user: user,
    box: box
  } do
    env = environment_fixture(user: user, box: box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#feature-update", "may have an older Foreman feature")
  end

  test "appears when the box's agent is upgraded while the page is open",
       %{conn: conn, user: user, box: box} do
    box = box |> Ecto.Changeset.change(feature_version: "1.0.0") |> Foreman.Repo.update!()
    env = environment_fixture(user: user, box: box, feature_version: "1.0.0")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#feature-update")

    {:ok, join} =
      ForemanProtocol.cast_join(%{
        "agent_version" => "0.5.0",
        "protocol_version" => ForemanProtocol.version(),
        "hostname" => "desktop",
        "os" => "linux",
        "arch" => "x86_64",
        "feature_version" => "1.1.0"
      })

    Foreman.Boxes.agent_joined(box, join)
    assert has_element?(view, "#feature-update", "desktop has 1.1.0")
  end

  test "nothing to say when it's up to date", %{conn: conn, user: user, box: box} do
    env = environment_fixture(user: user, box: box, feature_version: "1.1.0")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    refute has_element?(view, "#feature-update")
  end
end
