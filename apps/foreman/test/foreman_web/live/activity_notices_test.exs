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
      arch: "x86_64",
      policy: %{}
    })

    html = notice(view, :info)
    assert html =~ "dev"
    assert html =~ "Back online"
    assert html =~ ~s(href="/boxes/#{box.id}")
  end
end
