defmodule ForemanWeb.ActivityNoticesTest do
  use ForemanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Foreman.Operations

  setup :register_and_log_in

  setup %{user: user} do
    %{env: environment_fixture(user: user, slug: "storefront-1")}
  end

  defp finish(env, action, status, error \\ nil) do
    op =
      Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: env.id,
        box_id: env.box_id,
        action: action,
        command: "env." <> action,
        status: "running",
        args: %{}
      })

    {:ok, _} = Operations.finish(op.id, status, %{}, error)
  end

  defp notice(view, kind), do: view |> element("#flash-#{kind}") |> render()

  test "a finished rebuild shows up on whatever page you're on", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    finish(env, "rebuild", "ok")

    html = notice(view, :info)
    assert html =~ "storefront-1"
    assert html =~ "Rebuilt"
    assert html =~ ~s(href="/environments/#{env.id}")
  end

  test "a failure shows as an error, with why", %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/boxes")
    finish(env, "create", "error", "devcontainer up failed: exit 1")

    html = notice(view, :error)
    assert html =~ "storefront-1"
    assert html =~ "Create failed: devcontainer up failed: exit 1"
  end

  test "the environment's own page doesn't repeat what it already shows",
       %{conn: conn, env: env} do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    finish(env, "stop", "ok")

    refute has_element?(view, "#flash-info", "Stopped")
  end

  test "someone else's environment isn't your news", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    finish(environment_fixture(slug: "theirs-1"), "rebuild", "ok")

    refute has_element?(view, "#flash-info")
  end

  describe "running out of memory" do
    defp killed(env, ago, processes) do
      Foreman.Environments.record_guest_oom(env.box_id, env.id, %{
        at: System.os_time(:second) - ago,
        processes: processes
      })
    end

    test "a process killed inside a VM is news, with what it was", %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      killed(env, 1_000, ["orca", "node"])

      html = notice(view, :error)
      assert html =~ "storefront-1"
      assert html =~ "Out of memory: Linux killed orca and node"
      assert html =~ ~s(href="/environments/#{env.id}")
    end

    test "names two and counts the rest, or says a process when it has no name",
         %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      killed(env, 2_000, ["a", "b", "c", "d"])
      assert notice(view, :error) =~ "Linux killed a, b and 2 more"

      killed(env, 1_000, [])
      assert notice(view, :error) =~ "Linux killed a process"
    end

    # A VM short of memory loses one process after another.
    test "more kills in the next few minutes aren't news again", %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      killed(env, 1_000, ["orca"])
      assert notice(view, :error) =~ "orca"
      view |> element("#flash-error") |> render_click()
      refute has_element?(view, "#flash-error")

      killed(env, 985, ["node"])
      refute has_element?(view, "#flash-error")
      assert Foreman.Repo.reload!(env).last_guest_oom_processes == ["node"]

      killed(env, 300, ["node"])
      assert notice(view, :error) =~ "Linux killed node"
    end

    test "the box stopping the whole VM is news too", %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      Foreman.Environments.record_vm_oom(env.box_id, env.id, System.os_time(:second) - 60)

      html = notice(view, :error)
      assert html =~ "storefront-1"
      assert html =~ "Out of memory: the box stopped its VM"
    end

    test "the environment's own page shows it without a notice", %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
      killed(env, 60, ["orca"])

      assert has_element?(view, "#guest-oom")
      refute has_element?(view, "#flash-error")
    end

    test "someone else's isn't your news", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      killed(environment_fixture(slug: "theirs-1"), 60, ["orca"])

      refute has_element?(view, "#flash-error")
    end
  end

  test "a box coming back after a while", %{conn: conn, user: user} do
    box = box_fixture(owner_user_id: user.id, name: "dev")

    box
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(DateTime.utc_now(), -300))
    |> Foreman.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings")

    Foreman.Boxes.agent_joined(Foreman.Boxes.get_box!(box.id), %{
      agent_version: "0.4.5",
      protocol_version: 1,
      hostname: "dev",
      os: "linux",
      arch: "x86_64"
    })

    html = notice(view, :info)
    assert html =~ "dev"
    assert html =~ "Back online"
    assert html =~ ~s(href="/boxes/#{box.id}")
  end
end
