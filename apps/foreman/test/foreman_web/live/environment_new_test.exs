defmodule ForemanWeb.EnvironmentNewTest do
  use ForemanWeb.ConnCase

  setup :register_and_log_in_admin

  setup do
    %{repo: repo_fixture(name: "storefront")}
  end

  # Stands in for the agent's channel process.
  defp online(box) do
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    box
  end

  defp selected_box(view) do
    view
    |> element("#new-environment select[name='environment[box_id]'] option[selected]")
    |> render()
  end

  test "the placement notice follows the memory override and clears when it fits", %{
    conn: conn,
    user: user
  } do
    online(
      box_fixture(
        owner_user_id: user.id,
        capacity_policy: "refuse",
        capacity: %{"cpus" => 8, "memory_mb" => 16_000},
        vm: %{
          "ready" => true,
          "default_cpus" => 2,
          "default_memory_mb" => 4096,
          "host_cpus" => 8,
          "host_memory_mb" => 16_000
        }
      )
    )

    {:ok, view, _html} = live(conn, ~p"/environments/new")
    view |> form("#new-environment", environment: %{memory_limit_mb: "15900"}) |> render_change()
    assert has_element?(view, "#placement-refuse")

    view |> form("#new-environment", environment: %{memory_limit_mb: ""}) |> render_change()
    refute has_element?(view, "#placement-refuse")
  end

  test "an admin starts on their own box, not whichever sorts first", %{conn: conn, user: user} do
    other = user_fixture()
    online(box_fixture(owner_user_id: other.id, name: "alpha"))
    online(box_fixture(owner_user_id: user.id, name: "zeta"))

    {:ok, view, _html} = live(conn, ~p"/environments/new")
    assert selected_box(view) =~ "zeta"
  end

  test "a box shared with you comes before someone else's", %{conn: conn, user: user} do
    other = user_fixture()
    online(box_fixture(owner_user_id: other.id, name: "alpha"))
    online(box_fixture(owner_user_id: other.id, name: "beta", shared_user_ids: [user.id]))

    {:ok, view, _html} = live(conn, ~p"/environments/new")
    assert selected_box(view) =~ "beta"
  end

  test "an online box comes before your own offline one", %{conn: conn, user: user} do
    other = user_fixture()
    online(box_fixture(owner_user_id: other.id, name: "alpha"))
    box_fixture(owner_user_id: user.id, name: "zeta")

    {:ok, view, _html} = live(conn, ~p"/environments/new")
    assert selected_box(view) =~ "alpha"
  end

  test "a repo link for a repo that can't be picked falls back to one that can", %{
    conn: conn,
    user: user,
    repo: repo
  } do
    online(box_fixture(owner_user_id: user.id))
    gone = repo_fixture(name: "legacy", devcontainer_path: nil)

    {:ok, view, html} = live(conn, ~p"/environments/new?repo_id=#{gone.id}")

    # What's selected is what the details under the select describe.
    assert view
           |> element("#new-environment select[name='environment[repo_id]'] option[selected]")
           |> render() =~ repo.name

    assert html =~ repo.devcontainer_path
  end
end
