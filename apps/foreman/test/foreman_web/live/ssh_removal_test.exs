defmodule ForemanWeb.SSHRemovalTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Accounts, Repo}

  setup do
    previous = Application.get_env(:foreman, :tailscale)
    Application.put_env(:foreman, :tailscale, %{client_id: "test", client_secret: "test"})
    on_exit(fn -> Application.put_env(:foreman, :tailscale, previous || %{}) end)
    :ok
  end

  test "a tailnet administrator can acknowledge outstanding removal after reviewing the identity" do
    admin = user_fixture(role: "admin")
    member = user_fixture()
    env = environment_fixture(user: member)
    conn = log_in(build_conn(), admin)
    {:ok, view, _} = live(conn, ~p"/admin/users")

    view |> element("#user-#{member.id} [phx-click=disable]") |> render_click()
    assert has_element?(view, "#ssh-removals", member.login)
    assert has_element?(view, "#ssh-removals", "may still open new SSH sessions")
    assert Repo.reload!(env).observed_state == "running"

    {:ok, reopened, _} = live(conn, ~p"/admin/users")
    reopened |> element("#ssh-removals button", "Acknowledge removal") |> render_click()
    {:ok, checked, _} = live(conn, ~p"/admin/users")
    refute has_element?(checked, "#ssh-removals")
  end

  test "confirmed loss of org membership also persists a removal for admin review" do
    member = user_fixture()
    assert :ok = Accounts.revoke_access(member, "org membership ended")
    admin = user_fixture(role: "admin")
    {:ok, view, _} = live(log_in(build_conn(), admin), ~p"/admin/users")
    assert has_element?(view, "#ssh-removals", member.login)
  end

  test "disabled service installations link admins to an outstanding removal until acknowledged" do
    admin = user_fixture(role: "admin")
    scope = Foreman.Scope.for_user(admin)
    conn = log_in(build_conn(), admin)

    repo =
      repo_fixture() |> Ecto.Changeset.change(github_id: 1091, private: false) |> Repo.update!()

    {:ok, %{client: client}} =
      Foreman.OAuth.ServiceAccounts.register(scope, "service", %{
        "name" => "Build service",
        "scopes" => ["environments:start"],
        "repo_ids" => [repo.id],
        "box_ids" => [box_fixture().id]
      })

    {:ok, :disabled} = Foreman.OAuth.ServiceAccounts.disable(scope, client.id)
    assert html_response(get(conn, ~p"/admin/apps"), 200) =~ "/admin/users#ssh-removals"
    {:ok, view, _} = live(conn, ~p"/admin/users")
    assert has_element?(view, "#ssh-removals", "Build service")
    view |> element("#ssh-removals button", "Acknowledge removal") |> render_click()
    refute html_response(get(conn, ~p"/admin/apps"), 200) =~ "/admin/users#ssh-removals"
  end
end
