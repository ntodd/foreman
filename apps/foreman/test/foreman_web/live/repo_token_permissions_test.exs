defmodule ForemanWeb.RepoTokenPermissionsTest do
  @moduledoc "Admins choose what a repo's environment tokens may do, on the repo's page."
  use ForemanWeb.ConnCase

  alias Foreman.Repo

  setup :register_and_log_in_admin

  test "correcting a rejected save preserves comma-separated repos and tags", %{conn: conn} do
    repo = repo_fixture()
    {:ok, view, _html} = live(conn, ~p"/repos/#{repo.id}")
    repos = "shared-config, design-system"
    tags = "tag:staging, tag:build"

    view
    |> form("#repo-settings",
      settings: %{extra_repos: repos, tailscale_tags: tags, cpu_limit: "0"}
    )
    |> render_submit()

    assert has_element?(view, "#repo-settings", "must be greater than 0")

    assert has_element?(
             view,
             "#repo-settings input[name='settings[extra_repos]'][value='#{repos}']"
           )

    assert has_element?(
             view,
             "#repo-settings input[name='settings[tailscale_tags]'][value='#{tags}']"
           )

    view |> form("#repo-settings", settings: %{cpu_limit: "1"}) |> render_submit()
    saved = Repo.reload!(repo)
    assert saved.extra_repos == ["shared-config", "design-system"]
    assert saved.tailscale_tags == ["tag:staging", "tag:build"]
  end

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

  test "shows the extra repos the token gets from its owner beside the repo's own", %{conn: conn} do
    owner =
      owner_fixture(login: "acme")
      |> Ecto.Changeset.change(extra_repos: ["shared-config"])
      |> Repo.update!()

    repo = repo_fixture(owner: owner)
    {:ok, view, _html} = live(conn, ~p"/repos/#{repo.id}")

    assert has_element?(view, "#owner-extra-repos", "shared-config")
    assert has_element?(view, "#owner-extra-repos a[href='/admin']")
  end

  test "members don't see the control", %{conn: conn} do
    repo = repo_fixture()
    {:ok, view, _html} = live(log_in(conn, user_fixture()), ~p"/repos/#{repo.id}")
    refute has_element?(view, "select[name='settings[token_permissions][contents]']")
  end
end
