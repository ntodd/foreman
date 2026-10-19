defmodule ForemanWeb.UserFeaturesTest do
  @moduledoc "Each user's own devcontainer features: Settings, a repo's opt-outs, and the admin view."
  use ForemanWeb.ConnCase

  alias Foreman.{Accounts, Repo, Scope}

  @orca "ghcr.io/ntodd/devcontainer-features/orca:1"
  @node "ghcr.io/devcontainers/features/node:1"

  setup :register_and_log_in

  defp save_features(view, json) do
    view |> form("#features", features: %{json: json}) |> render_submit()
  end

  describe "Settings" do
    test "saves features written the way devcontainer.json has them", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = save_features(view, ~s({"#{@orca}": {"server": true}, "#{@node}": {}}))

      assert html =~ "next rebuild"

      assert Repo.reload!(user).devcontainer_features == %{
               @orca => %{"server" => true},
               @node => %{}
             }

      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ @orca
    end

    test "says what's wrong and saves nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert save_features(view, "{not json") =~ "isn&#39;t valid JSON"
      assert save_features(view, ~s({"ghcr.io/mona/features/foreman:1": {}})) =~ "Foreman"
      assert Repo.reload!(user).devcontainer_features == %{}
    end

    test "an empty box clears them", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_features(Scope.for_user(user), %{@orca => %{}})
      {:ok, view, _html} = live(conn, ~p"/settings")

      save_features(view, "")
      assert Repo.reload!(user).devcontainer_features == %{}
    end

    test "nobody else sees them", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_features(Scope.for_user(user), %{@orca => %{}})
      other = user_fixture()

      {:ok, _view, html} = live(log_in(conn, other), ~p"/settings")
      refute html =~ @orca
    end
  end

  describe "a repo's page" do
    test "turns features off for that repo", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_features(Scope.for_user(user), %{@orca => %{}, @node => %{}})
      repo = repo_fixture()

      {:ok, view, html} = live(conn, ~p"/repos/#{repo.id}")
      assert html =~ @orca
      assert html =~ @node

      view
      |> form("#repo-features", %{repo_features: %{on: ["ghcr.io/devcontainers/features/node"]}})
      |> render_submit()

      assert Accounts.effective_features(Repo.reload!(user), repo) == %{@node => %{}}

      # Every box unticked.
      view |> form("#repo-features") |> render_submit(%{repo_features: %{on: [""]}})
      assert Accounts.effective_features(Repo.reload!(user), repo) == %{}
    end

    test "says where to add them when there are none", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/repos/#{repo_fixture().id}")
      refute has_element?(view, "#repo-features")
      assert html =~ "add your own devcontainer features in"
    end
  end

  describe "People (admins)" do
    setup %{conn: conn} do
      admin = user_fixture(role: "admin")
      %{conn: log_in(conn, admin)}
    end

    test "lists each person's features", %{conn: conn, user: user} do
      {:ok, _} = Accounts.update_features(Scope.for_user(user), %{@orca => %{"server" => true}})

      {:ok, view, _html} = live(conn, ~p"/admin/users")
      assert view |> element("#user-#{user.id}") |> render() =~ @orca
    end
  end
end
