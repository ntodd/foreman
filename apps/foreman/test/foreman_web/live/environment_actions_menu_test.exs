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

  test "the last VM OOM remains visible after the VM is running again", %{
    conn: conn,
    env: env,
    box: box
  } do
    {:ok, view, _} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#vm-oom")
    Foreman.Environments.record_vm_oom(box.id, env.id, 1_735_689_600)
    assert has_element?(view, "#vm-oom", "memory pressure")
    assert has_element?(view, "#vm-oom-at[datetime='2025-01-01T00:00:00Z']")
  end

  test "says what the kernel last killed inside the VM, and when", %{
    conn: conn,
    env: env,
    box: box
  } do
    {:ok, view, _} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#guest-oom")

    Foreman.Environments.record_guest_oom(box.id, env.id, %{
      at: 1_735_689_600,
      processes: ["orca", "node"]
    })

    text =
      view
      |> element("#guest-oom")
      |> render()
      |> String.replace(~r/<[^>]+>/, "")
      |> String.replace(~r/\s+/, " ")

    assert text =~ "Linux killed orca, node in this VM when it ran out of memory."
    assert has_element?(view, "#guest-oom [data-role=killed]", "orca, node")
    assert has_element?(view, "#guest-oom-at[datetime='2025-01-01T00:00:00Z']")
    # Its VM wasn't stopped.
    refute has_element?(view, "#vm-oom")

    Foreman.Environments.record_guest_oom(box.id, env.id, %{at: 1_735_689_700, processes: []})
    assert has_element?(view, "#guest-oom", "a process")
    refute has_element?(view, "#guest-oom [data-role=killed]")
  end

  test "offers both rebuilds and says what each does", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    assert has_element?(view, "#env-actions [role=menuitem]", "Rebuild")
    assert has_element?(view, "#env-actions [role=menuitem]", "Keeps the clone as it is")
    assert has_element?(view, "#env-actions [role=menuitem]", "Pull and rebuild")
    assert has_element?(view, "#env-actions [role=menuitem]", "origin/feature/x")
  end

  test "warns about a fresh clone on every recovery action after a failed create", %{
    conn: conn,
    user: user,
    box: box
  } do
    env = environment_fixture(user: user, box: box, observed_state: "error", created_once: false)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

    for action <- ~w(retry rebuild pull_rebuild) do
      assert has_element?(view, "[phx-value-do=#{action}][data-confirm*='fresh clone']")
    end

    refute has_element?(view, "#env-actions", "Keeps the clone as it is")
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

  for page <- [:index, :show] do
    @page page
    test "starting over capacity from the #{page} asks before queuing", %{
      conn: conn,
      box: box,
      env: env
    } do
      box
      |> Ecto.Changeset.change(
        capacity_policy: "warn",
        vm: %{
          "default_cpus" => 2,
          "default_memory_mb" => 2048,
          "host_cpus" => 2,
          "host_memory_mb" => 2048
        },
        capacity: %{"cpus" => 2, "memory_mb" => 2048}
      )
      |> Foreman.Repo.update!()

      env
      |> Ecto.Changeset.change(observed_state: "stopped", desired_state: "stopped")
      |> Foreman.Repo.update!()

      {path, start} =
        if @page == :index,
          do: {~p"/", "#env-#{env.id} button[phx-click=start]"},
          else: {~p"/environments/#{env.id}", "button[phx-value-do=start]"}

      {:ok, view, _} = live(conn, path)
      view |> element(start) |> render_click()
      assert has_element?(view, "#start-warning", "memory")
      assert Foreman.Repo.reload!(env).desired_state == "stopped"
      view |> element("#start-warning button", "Start anyway") |> render_click()
      assert Foreman.Repo.reload!(env).desired_state == "running"
      refute has_element?(view, "#start-warning")
    end
  end

  test "confirming a rebuild warning queues the selected operation", %{
    conn: conn,
    box: box,
    env: env
  } do
    box
    |> Ecto.Changeset.change(
      capacity_policy: "warn",
      vm: %{
        "default_cpus" => 2,
        "default_memory_mb" => 2048,
        "host_cpus" => 2,
        "host_memory_mb" => 2048
      },
      capacity: %{"cpus" => 2, "memory_mb" => 2048}
    )
    |> Foreman.Repo.update!()

    env
    |> Ecto.Changeset.change(observed_state: "stopped", desired_state: "stopped")
    |> Foreman.Repo.update!()

    {:ok, view, _} = live(conn, ~p"/environments/#{env.id}")
    render_click(view, "action", %{"do" => "rebuild"})
    view |> element("#start-warning button", "Rebuild anyway") |> render_click()

    assert Foreman.Repo.get_by(Foreman.Operations.Operation,
             environment_id: env.id,
             action: "rebuild"
           )
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

  test "suspends a running environment, and offers Start for a suspended one", %{
    conn: conn,
    env: env
  } do
    env |> Ecto.Changeset.change(observed_state: "running") |> Foreman.Repo.update!()
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    assert has_element?(view, "#env-actions [role=menuitem]", "Saves the VM's memory to disk")
    view |> element("#env-actions [role=menuitem][phx-value-do=suspend]") |> render_click()
    assert [%{action: "suspend"} | _] = Operations.list_for_environment(env.id)

    env
    |> Ecto.Changeset.change(observed_state: "suspended", created_once: true)
    |> Foreman.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#env-actions [phx-value-do=suspend]")
    assert has_element?(view, "button[phx-value-do=start]", "Start")
    assert render(view) =~ "Suspended"
  end
end
