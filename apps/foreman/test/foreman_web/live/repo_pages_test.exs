defmodule ForemanWeb.RepoPagesTest do
  @moduledoc """
  The Repos list's totals and what each row says of a repo, and the repo
  page's summary row, details and environment list.
  """
  use ForemanWeb.ConnCase

  alias Foreman.Prebuilds
  alias Foreman.Prebuilds.Prebuild
  alias Foreman.Repo

  defp prebuild(repo, box, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Prebuild{
          repo_id: repo.id,
          box_id: box.id,
          branch: repo.default_branch,
          config_path: repo.devcontainer_path,
          status: "ready",
          built_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  setup :register_and_log_in_admin

  setup %{user: user} do
    owner = owner_fixture()
    api = repo_fixture(owner: owner, name: "api", cpu_limit: 4.0, memory_limit_mb: 8_192)
    docs = repo_fixture(owner: owner, name: "docs", token_mode: "broad")
    desktop = box_fixture(owner_user_id: user.id, name: "desktop", vm: %{"ready" => true})
    rack = box_fixture(owner_user_id: user.id, name: "rack", vm: %{"ready" => true})

    environment_fixture(user: user, repo: api, box: desktop, slug: "api-1")

    environment_fixture(
      user: user,
      repo: api,
      box: rack,
      slug: "api-2",
      branch: "fix-login",
      desired_state: "stopped",
      observed_state: "stopped"
    )

    prebuild(api, desktop)

    %{api: api, docs: docs, desktop: desktop, rack: rack}
  end

  describe "Prebuilds.ready_box_counts/2" do
    test "counts the boxes new environments of each repo start from a prebuild on", ctx do
      # Not what new environments start from: another branch, a failed one, a box out of view.
      prebuild(ctx.api, ctx.rack, branch: "old-default")
      prebuild(ctx.docs, ctx.rack, status: "failed", built_at: nil)
      prebuild(ctx.docs, box_fixture(name: "elsewhere"))

      boxes = [ctx.desktop.id, ctx.rack.id]
      assert Prebuilds.ready_box_counts([ctx.api, ctx.docs], boxes) == %{ctx.api.id => 1}

      prebuild(ctx.api, ctx.rack)
      prebuild(ctx.api, ctx.rack)
      assert Prebuilds.ready_box_counts([ctx.api, ctx.docs], boxes) == %{ctx.api.id => 2}
      assert Prebuilds.ready_box_counts([], boxes) == %{}
    end
  end

  describe "the Repos list" do
    test "totals the repos, their environments and their prebuilds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/repos")

      assert has_element?(view, "#repos-total", "2")
      assert has_element?(view, "#repos-total", "All healthy")
      assert has_element?(view, "#repos-environments", "2")
      assert has_element?(view, "#repos-environments", "1 running")
      assert has_element?(view, "#repos-prebuilds", "1 of 2")
    end

    test "says what each repo has", %{conn: conn, api: api, docs: docs} do
      {:ok, view, _html} = live(conn, ~p"/repos")

      assert has_element?(view, "#repo-#{api.id} [data-role=environments]", "2 environments")
      assert has_element?(view, "#repo-#{api.id} [data-role=environments]", "1 running")
      assert has_element?(view, "#repo-#{api.id} [data-role=prebuilt]", "Prebuilt")

      refute has_element?(view, "#repo-#{docs.id} [data-role=environments]")
      refute has_element?(view, "#repo-#{docs.id} [data-role=prebuilt]")
      assert has_element?(view, "#repo-#{docs.id}", "Broad token")
    end

    test "counts a repo whose devcontainer has a problem", %{conn: conn, docs: docs} do
      docs |> Ecto.Changeset.change(devcontainer_error: "No service named app") |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/repos")
      assert has_element?(view, "#repos-total", "1 needs attention")
    end

    test "an admin jumps to the add form from the header, and adds a repo", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/repos")
      assert has_element?(view, "header a[href='#add-repo']", "Add repo")

      view |> form("#add-repo-form", repo: %{full_name: "octo/widgets"}) |> render_submit()
      {path, _flash} = assert_redirect(view)
      assert path =~ ~r"^/repos/"
    end
  end

  describe "a repo's page" do
    test "sums the repo up above its panels", %{conn: conn, api: api, docs: docs} do
      {:ok, view, _html} = live(conn, ~p"/repos/#{api.id}")

      assert has_element?(view, "#stat-environments", "2")
      assert has_element?(view, "#stat-environments", "1 running")
      assert has_element?(view, "#stat-size", "4 CPUs")
      assert has_element?(view, "#stat-size", "8.0 GiB")
      assert has_element?(view, "#stat-size", "The repo's limits")
      assert has_element?(view, "#stat-token", "Scoped")
      assert has_element?(view, "#stat-prebuilds", "1 of 2")

      {:ok, view, _html} = live(conn, ~p"/repos/#{docs.id}")
      assert has_element?(view, "#stat-environments", "0")
      assert has_element?(view, "#stat-size", "Box default")
      assert has_element?(view, "#stat-token", "Broad")
      assert has_element?(view, "#stat-prebuilds", "0 of 2")
    end

    test "lists its details and where each environment is", %{conn: conn, api: api} do
      {:ok, view, _html} = live(conn, ~p"/repos/#{api.id}")

      assert has_element?(view, "#repo-details", api.owner.login)
      assert has_element?(view, "#repo-details", "main")
      assert has_element?(view, "#repo-details", "Private")
      assert has_element?(view, "#repo-details", ".devcontainer/devcontainer.json")

      assert has_element?(view, "#repo-environments li", "api-2")
      assert has_element?(view, "#repo-environments li", "fix-login")
      assert has_element?(view, "#repo-environments li", "rack")
    end

    # A VM's size is the repo's limits or the box's default; hostRequirements only says what it wants.
    test "says what the devcontainer wants when the repo sets no limits", %{conn: conn} do
      repo = repo_fixture(host_requirements: %{"cpus" => 2, "memory" => "4gb"})

      {:ok, view, _html} = live(conn, ~p"/repos/#{repo.id}")
      assert has_element?(view, "#stat-size", "Box default")
      assert has_element?(view, "#stat-size", "Wants 2 CPUs, 4gb")
    end
  end
end
