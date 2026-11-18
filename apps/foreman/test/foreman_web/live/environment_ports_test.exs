defmodule ForemanWeb.EnvironmentPortsTest do
  # The ports listening in an environment, as links on the tailnet.
  use ForemanWeb.ConnCase, async: false

  alias Foreman.Ports

  setup :register_and_log_in

  setup %{user: user} do
    Application.put_env(:foreman, :tailscale, %{client_id: "c", client_secret: "s"})
    on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)

    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

    env =
      environment_fixture(user: user, box: box, slug: "storefront-2")
      |> Ecto.Changeset.change(remote_user: "vscode", workspace_folder: "/workspaces/storefront")
      |> Foreman.Repo.update!()

    %{box: box, env: env}
  end

  test "links each listening port on the tailnet, with its process", %{
    conn: conn,
    box: box,
    env: env
  } do
    Ports.record(box.id, %{env.id => [%{port: 4000, process: "beam.smp"}, %{port: 5173}]})
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, ~s|#ports a[href="http://storefront-2:4000"]|, "storefront-2:4000")
    assert has_element?(view, "#port-4000", "beam.smp")
    assert has_element?(view, ~s|#ports a[href="http://storefront-2:5173"]|)
    refute has_element?(view, "#ports-none")
    # Opens beside Foreman, not in place of it.
    assert has_element?(view, ~s|#port-4000 a[target="_blank"][rel~="noopener"]|)
  end

  test "updates as servers start and stop", %{conn: conn, box: box, env: env} do
    Ports.record(box.id, %{env.id => []})
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    assert has_element?(view, "#ports-none", "Nothing is listening")
    assert has_element?(view, "#ports-none", "http://storefront-2:PORT")

    Ports.record(box.id, %{env.id => [%{port: 5000, process: "beam.smp"}]})
    assert has_element?(view, ~s|#ports a[href="http://storefront-2:5000"]|)
    refute has_element?(view, "#ports-none")

    Ports.record(box.id, %{env.id => []})
    refute has_element?(view, "#port-5000")
    assert has_element?(view, "#ports-none")
  end

  # An agent from before ports never reports them, and one that can't
  # read an environment leaves it out: that isn't "nothing listening".
  test "ports nobody has reported fall back to the general hint", %{
    conn: conn,
    box: box,
    env: env
  } do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#ports")
    assert has_element?(view, "#ports-hint", "http://storefront-2:PORT")

    Ports.record(box.id, %{env.id => []})
    assert has_element?(view, "#ports-none")
    refute has_element?(view, "#ports-hint")

    Ports.record(box.id, %{env.id => [%{port: 4000}]})
    assert has_element?(view, "#port-4000")

    Ports.record(box.id, %{})
    refute has_element?(view, "#ports")
    assert has_element?(view, "#ports-hint")
  end

  test "another environment's ports don't show up", %{conn: conn, box: box, env: env, user: user} do
    other = environment_fixture(user: user, box: box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    Ports.record(box.id, %{env.id => [], other.id => [%{port: 9999}]})
    # A round trip, so the page has handled anything it was sent.
    _ = render(view)
    refute has_element?(view, "#port-9999")
  end

  test "a stopped environment or an offline box shows no ports", %{conn: conn, box: box, env: env} do
    Ports.record(box.id, %{env.id => [%{port: 4000}]})

    env |> Ecto.Changeset.change(observed_state: "stopped") |> Foreman.Repo.update!()
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#ports")

    env |> Ecto.Changeset.change(observed_state: "running") |> Foreman.Repo.update!()
    Registry.unregister(Foreman.Registry, {:agent, box.id})
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#ports")
  end

  test "without Tailscale, nothing to link to", %{conn: conn, box: box, env: env} do
    Application.delete_env(:foreman, :tailscale)
    Ports.record(box.id, %{env.id => [%{port: 4000}]})
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#ports")
    refute has_element?(view, "#ports-hint")
    assert has_element?(view, "#tailscale-off")
  end

  test "process names are text, not markup", %{conn: conn, box: box, env: env} do
    Ports.record(box.id, %{env.id => [%{port: 4000, process: "<img src=x onerror=alert(1)>"}]})
    {:ok, view, html} = live(conn, ~p"/environments/#{env.id}")

    refute html =~ "<img src=x"
    assert has_element?(view, "#port-4000", "<img src=x onerror=alert(1)>")
  end
end
