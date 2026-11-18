defmodule ForemanWeb.EnvironmentConnectTest do
  # The actions a feature's connect hook puts on the environment's page,
  # and the result shown once to the person who asked.
  use ForemanWeb.ConnCase

  alias Foreman.{Agents, Operations, Repo}
  alias ForemanProtocol.{Command, Event}

  @orca %{
    "name" => "orca",
    "label" => "Orca",
    "actions" => [
      %{"id" => "desktop", "label" => "Pair a desktop", "confirm" => "Orca restarts."},
      %{"id" => "mobile", "label" => "Pair a phone", "confirm" => nil}
    ]
  }

  @code "orca://pair?code=s3cretc0de"

  setup :register_and_log_in

  setup %{user: user} do
    box = box_fixture(owner_user_id: user.id, name: "desktop")
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{box: box}
  end

  defp env_with_hooks(user, box, attrs \\ []) do
    environment_fixture(Keyword.merge([user: user, box: box], attrs))
    |> Ecto.Changeset.change(connect_hooks: [@orca], remote_user: "vscode")
    |> Repo.update!()
  end

  defp agent_result(box, attrs) do
    assert_receive {:dispatch, %Command{type: "env.connect"} = cmd}
    {:ok, ev} = Event.new("op.result", Map.put(attrs, :op_id, cmd.op_id))
    :ok = Agents.handle_event(box.id, ev)
  end

  # The page's own git status check goes out first.
  defp drain_git_status,
    do: receive(do: ({:dispatch, %Command{type: "env.git_status"}} -> :ok), after: (0 -> :ok))

  test "lists the hook's actions under Connect, with their confirmations", %{
    conn: conn,
    user: user,
    box: box
  } do
    env = env_with_hooks(user, box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#connect-hooks", "Orca")

    assert has_element?(
             view,
             ~s(#connect-orca-desktop[data-confirm="Orca restarts."]),
             "Pair a desktop"
           )

    assert has_element?(view, "#connect-orca-mobile", "Pair a phone")
    refute has_element?(view, "#connect-orca-mobile[data-confirm]")
  end

  test "shows nothing for an environment without hooks", %{conn: conn, user: user, box: box} do
    env = environment_fixture(user: user, box: box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#connect-hooks")
  end

  test "an admin looking at someone else's environment doesn't get the actions", %{box: box} do
    owner = user_fixture()
    env = env_with_hooks(owner, box)
    admin = user_fixture(role: "admin")
    conn = log_in(build_conn(), admin)

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#connect-hooks")
  end

  test "the actions wait for the environment to be running", %{conn: conn, user: user, box: box} do
    env = env_with_hooks(user, box, observed_state: "stopped")
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#connect-orca-desktop[disabled]")
  end

  test "shows the result once it comes back, and forgets it when closed", %{
    conn: conn,
    user: user,
    box: box
  } do
    env = env_with_hooks(user, box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    drain_git_status()

    view |> element("#connect-orca-desktop") |> render_click()
    assert has_element?(view, "#connect-modal", "Pair a desktop")
    assert has_element?(view, "#connect-modal", "Waiting for Orca")

    agent_result(box, %{
      status: "ok",
      result: %{"offer" => %{"value" => @code, "qr" => false, "note" => "Paste it into Orca."}}
    })

    assert has_element?(view, "#connect-value", @code)
    assert has_element?(view, "#connect-modal", "Paste it into Orca.")
    refute has_element?(view, "#connect-qr")

    [op | _] = Operations.list_for_environment(env.id)
    assert op.action == "connect"
    refute inspect(Operations.get!(op.id)) =~ "s3cretc0de"

    view |> element("#connect-modal-close") |> render_click()
    refute has_element?(view, "#connect-modal")
    refute render(view) =~ "s3cretc0de"
  end

  test "a phone gets a QR code", %{conn: conn, user: user, box: box} do
    env = env_with_hooks(user, box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    drain_git_status()

    view |> element("#connect-orca-mobile") |> render_click()
    agent_result(box, %{status: "ok", result: %{"offer" => %{"value" => @code, "qr" => true}}})

    assert has_element?(view, "#connect-qr svg path")
    assert has_element?(view, "#connect-value", @code)
  end

  test "a failure says why", %{conn: conn, user: user, box: box} do
    env = env_with_hooks(user, box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    drain_git_status()

    view |> element("#connect-orca-desktop") |> render_click()
    agent_result(box, %{status: "error", error: "connect hook orca failed: no pairing offer"})

    assert has_element?(view, "#connect-modal", "no pairing offer")
    refute has_element?(view, "#connect-value")
    refute has_element?(view, "#connect-modal", "shown here once")
  end

  test "another page on the same environment doesn't see the result", %{
    conn: conn,
    user: user,
    box: box
  } do
    env = env_with_hooks(user, box)
    {:ok, asker, _html} = live(conn, ~p"/environments/#{env.id}")
    {:ok, other, _html} = live(conn, ~p"/environments/#{env.id}")
    drain_git_status()
    drain_git_status()

    asker |> element("#connect-orca-desktop") |> render_click()
    agent_result(box, %{status: "ok", result: %{"offer" => %{"value" => @code}}})

    assert has_element?(asker, "#connect-value", @code)
    refute render(other) =~ "s3cretc0de"
  end
end
