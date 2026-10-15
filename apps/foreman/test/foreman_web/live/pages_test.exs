defmodule ForemanWeb.PagesTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Environments, Repo, Scope}

  setup :register_and_log_in_admin

  setup %{user: user} do
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id, name: "desktop")
    %{repo: repo, box: box}
  end

  test "every page renders", %{conn: conn, repo: repo, box: box, user: user} do
    env = environment_fixture(user: user, repo: repo, box: box)

    for path <- [
          "/",
          "/environments/new",
          "/environments/#{env.id}",
          "/repos",
          "/repos/#{repo.id}",
          "/boxes",
          "/boxes/#{box.id}",
          "/secrets",
          "/settings",
          "/admin",
          "/admin/users",
          "/admin/audit"
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "Foreman", "#{path} didn't render"
    end
  end

  test "creating an environment from the form", %{conn: conn, repo: repo, box: box} do
    {:ok, view, _html} = live(conn, ~p"/environments/new")

    {:error, {:live_redirect, %{to: "/environments/" <> _}}} =
      view
      |> form("#new-environment",
        environment: %{repo_id: repo.id, box_id: box.id, branch: "main"}
      )
      |> render_submit()

    assert [%{slug: "storefront-1"}] =
             Environments.list_environments(
               Scope.for_user(Repo.get_by!(Foreman.Accounts.User, role: "admin"))
             )
  end

  test "a warn-policy box asks for confirmation first", %{conn: conn, user: user} do
    big = repo_fixture(name: "monolith", host_requirements: %{"cpus" => 64})
    box = box_fixture(owner_user_id: user.id, capacity_policy: "warn")
    {:ok, view, _html} = live(conn, ~p"/environments/new")

    html =
      view
      |> form("#new-environment", environment: %{repo_id: big.id, box_id: box.id})
      |> render_submit()

    assert html =~ "Create anyway"
    assert html =~ "64 CPUs"
  end

  test "with Tailscale, a started environment shows SSH and an Open in VS Code link", %{
    conn: conn,
    user: user,
    repo: repo,
    box: box
  } do
    Application.put_env(:foreman, :tailscale, %{client_id: "c", client_secret: "s"})
    on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)

    env = environment_fixture(user: user, repo: repo, box: box)

    env =
      Repo.update!(
        Ecto.Changeset.change(env,
          remote_user: "vscode",
          workspace_folder: "/workspaces/storefront",
          devcontainer_service: "app"
        )
      )

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    assert has_element?(view, "#ssh-command", "ssh vscode@#{env.slug}")

    assert has_element?(
             view,
             ~s|a[href="vscode://vscode-remote/ssh-remote+vscode@#{env.slug}/workspaces/storefront"]|,
             "Open in VS Code"
           )
  end

  test "without Tailscale, a started environment says why SSH and VS Code are missing", %{
    conn: conn,
    user: user,
    repo: repo,
    box: box
  } do
    env = environment_fixture(user: user, repo: repo, box: box)

    env =
      Repo.update!(
        Ecto.Changeset.change(env,
          remote_user: "vscode",
          workspace_folder: "/workspaces/storefront",
          devcontainer_service: "app"
        )
      )

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    refute has_element?(view, "#ssh-command")
    assert has_element?(view, "#tailscale-off", "FOREMAN_TAILSCALE_CLIENT_ID")
  end

  test "the environment page offers restart now or later after a secrets change", %{
    conn: conn,
    user: user,
    repo: repo,
    box: box
  } do
    env = environment_fixture(user: user, repo: repo, box: box)

    Repo.update!(
      Ecto.Changeset.change(env, pending_restart: true, pending_changes: ["NEON_API_KEY"])
    )

    {:ok, view, html} = live(conn, ~p"/environments/#{env.id}")
    assert html =~ "Secrets changed: NEON_API_KEY"
    assert has_element?(view, "button", "Restart affected")
    assert has_element?(view, "button", "Restart all")

    view |> element("button", "Later") |> render_click()
    refute has_element?(view, "#pending-restart")

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("button", "Restart affected") |> render_click()

    assert [%{action: "restart_affected", args: %{"changed" => ["NEON_API_KEY"]}} | _] =
             Foreman.Operations.list_for_environment(env.id)
  end

  test "destroying asks git first and requires typing the slug when work would be lost", %{
    conn: conn,
    user: user,
    repo: repo,
    box: box
  } do
    env = environment_fixture(user: user, repo: repo, box: box)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    view |> element("button", "Destroy") |> render_click()
    assert render(view) =~ "Checking for unsaved work"

    assert_receive {:dispatch, %{type: "env.git_status", op_id: op_id}}

    {:ok, op} =
      Foreman.Operations.finish(
        op_id,
        "ok",
        %{"clean" => false, "changed_files" => 3, "unpushed_commits" => 1, "branch" => "main"},
        nil
      )

    send(view.pid, {:operation, op})

    html = render(view)
    assert html =~ "3 uncommitted changes and 1 unpushed commit"
    assert view |> element("#destroy-modal button", "Destroy") |> render() =~ "disabled"

    view |> form("#destroy-modal form", %{confirm: env.slug}) |> render_change()
    view |> element("#destroy-modal button", "Destroy") |> render_click()
    assert Repo.reload!(env).desired_state == "destroyed"
  end

  test "secrets are added and never shown back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/secrets")

    view
    |> form("#user-secrets-form", secret: %{name: "OPENAI_API_KEY", value: "sk-very-secret"})
    |> render_submit()

    html = render(view)
    assert html =~ "OPENAI_API_KEY"
    refute html =~ "sk-very-secret"
  end

  test "a box that opens up its policy gets a red alert everywhere it's shown", %{
    conn: conn,
    user: user
  } do
    open =
      box_fixture(
        owner_user_id: user.id,
        name: "open",
        policy:
          Map.merge(ForemanProtocol.Policy.defaults(), %{
            "privileged" => "allow",
            "host_bind" => "warn"
          })
      )

    {:ok, view, _html} = live(conn, ~p"/boxes/#{open.id}")
    assert has_element?(view, "#box-policy-alert", "privileged")
    assert has_element?(view, "#box-policy-alert", "root on the box")
    assert has_element?(view, "#box-policy-alert", "bind mounts from outside the workspace")
    assert has_element?(view, "#box-policy-alert", "FOREMAN_POLICY")

    {:ok, view, _html} = live(conn, ~p"/boxes")
    assert has_element?(view, "#box-#{open.id} [data-role=policy-alert]", "Privileged allowed")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#box-card-#{open.id} [data-role=policy-alert]",
             "Privileged allowed"
           )
  end

  test "a box on the default policy, or one that hasn't reported it, has no alert", %{
    conn: conn,
    box: box,
    user: user
  } do
    unknown = box_fixture(owner_user_id: user.id, name: "unknown", policy: nil)

    for b <- [box, unknown] do
      {:ok, view, _html} = live(conn, ~p"/boxes/#{b.id}")
      refute has_element?(view, "#box-policy-alert")
    end

    {:ok, view, _html} = live(conn, ~p"/boxes")
    refute has_element?(view, "[data-role=policy-alert]")
  end

  test "adding a box shows a one-time install command", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boxes")
    html = view |> form("#join-token-form", box: %{box_name: "work-box"}) |> render_submit()
    assert html =~ "/agent/install.sh | sudo sh -s -- --token fj_"
  end

  test "members can't see other people's environments", %{repo: repo} do
    other = user_fixture()
    env = environment_fixture(user: other, repo: repo)
    member = user_fixture()
    conn = log_in(build_conn(), member)

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/environments/#{env.id}") end
  end
end
