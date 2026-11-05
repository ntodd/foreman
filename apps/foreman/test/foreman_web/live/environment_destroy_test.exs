defmodule ForemanWeb.EnvironmentDestroyTest do
  use ForemanWeb.ConnCase

  alias Foreman.Repo

  setup :register_and_log_in_admin

  setup %{user: user} do
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{env: environment_fixture(user: user, repo: repo, box: box)}
  end

  # Opens the destroy dialog and answers its git check with work to lose.
  defp open_destroy(conn, env) do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("#env-actions [role=menuitem]", "Destroy") |> render_click()
    assert_receive {:dispatch, %{type: "env.git_status", op_id: op_id}}

    {:ok, op} =
      Foreman.Operations.finish(
        op_id,
        "ok",
        %{"clean" => false, "changed_files" => 1, "unpushed_commits" => 0, "branch" => "main"},
        nil
      )

    send(view.pid, {:operation, op})
    assert render(view) =~ "Type #{env.slug} to confirm"
    view
  end

  test "Enter in the confirmation destroys once the slug is typed", %{conn: conn, env: env} do
    view = open_destroy(conn, env)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> form("#confirm-destroy", %{confirm: env.slug}) |> render_submit()

    assert Repo.reload!(env).desired_state == "destroyed"
  end

  test "Enter with the wrong name leaves it alone", %{conn: conn, env: env} do
    view = open_destroy(conn, env)
    view |> form("#confirm-destroy", %{confirm: "nope"}) |> render_submit()

    assert has_element?(view, "#confirm-destroy")
    assert Repo.reload!(env).desired_state == "running"
  end

  describe "events the page doesn't send" do
    test "leave the page up", %{conn: conn, env: env} do
      {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")

      render_hook(view, "cancel_op", %{"id" => "not-a-uuid"})
      render_hook(view, "action", %{"do" => "format_disk"})
      render_hook(view, "confirm_input", %{"confirm" => env.slug})
      render_hook(view, "destroy", %{"confirm" => env.slug})

      assert render(view) =~ env.slug
      assert Repo.reload!(env).desired_state == "running"
    end
  end
end
