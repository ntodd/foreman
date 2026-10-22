defmodule ForemanWeb.RepoTokenPermissionsTest do
  @moduledoc "Admins choose what a repo's environment tokens may do, on the repo's page."
  use ForemanWeb.ConnCase

  alias Foreman.Repo

  setup :register_and_log_in_admin

  test "saves a permission change", %{conn: conn} do
    repo = repo_fixture()
    {:ok, view, html} = live(conn, ~p"/repos/#{repo.id}")

    assert html =~ "Workflows"
    assert has_element?(view, "select[name='settings[token_permissions][actions]']")

    view
    |> form("#repo-settings", settings: %{token_permissions: %{actions: "none", pages: "write"}})
    |> render_submit()

    perms = Repo.reload!(repo).token_permissions
    assert perms["actions"] == "none"
    assert perms["pages"] == "write"
    assert perms["contents"] == "write"
  end

  test "flags permissions the GitHub App's installation doesn't have", %{conn: conn} do
    owner =
      owner_fixture(
        installation_permissions: %{
          "contents" => "write",
          "pull_requests" => "write",
          "issues" => "write",
          "workflows" => "write",
          "metadata" => "read"
        }
      )

    repo = repo_fixture(owner: owner)
    {:ok, view, _html} = live(conn, ~p"/repos/#{repo.id}")

    assert has_element?(view, "#permission-actions [data-role='not-granted']")
    refute has_element?(view, "#permission-contents [data-role='not-granted']")
  end

  test "members don't see the control", %{conn: conn} do
    repo = repo_fixture()
    {:ok, view, _html} = live(log_in(conn, user_fixture()), ~p"/repos/#{repo.id}")
    refute has_element?(view, "select[name='settings[token_permissions][contents]']")
  end
end
