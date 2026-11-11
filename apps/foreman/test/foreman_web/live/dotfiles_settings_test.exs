defmodule ForemanWeb.DotfilesSettingsTest do
  @moduledoc "Where the dotfiles go: a default in Settings, and a repo's override."
  use ForemanWeb.ConnCase

  alias Foreman.{Accounts, Repo}

  setup :register_and_log_in

  test "Settings saves where the dotfiles go", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#preferences",
      user: %{
        dotfiles_repository: "https://github.com/mona/dotfiles.git",
        dotfiles_target_path: "~/.dotfiles"
      }
    )
    |> render_submit()

    assert Repo.reload!(user).dotfiles_target_path == "~/.dotfiles"
  end

  test "Settings refuses a path the clone script would run", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("#preferences", user: %{dotfiles_target_path: "~/x; rm -rf ~"})
      |> render_submit()

    assert html =~ "must be a path under ~/"
    assert Repo.reload!(user).dotfiles_target_path == nil
  end

  test "a repo's page overrides where the dotfiles go", %{conn: conn, user: user} do
    repo = repo_fixture()
    {:ok, view, _html} = live(conn, ~p"/repos/#{repo.id}")

    view
    |> form("#override-form", override: %{dotfiles_target_path: "~/.dotfiles"})
    |> render_submit()

    assert Accounts.effective_identity(Repo.reload!(user), repo).dotfiles_target_path ==
             "~/.dotfiles"
  end
end
