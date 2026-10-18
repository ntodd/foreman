defmodule ForemanWeb.EnvironmentBranchSyncTest do
  # The environment page says whether the clone is behind its branch.
  use ForemanWeb.ConnCase

  import Mox

  alias Foreman.GitHub.ClientMock
  alias Foreman.Operations

  @head "1111111111111111111111111111111111111111"

  setup :set_mox_global
  setup :verify_on_exit!
  setup :register_and_log_in

  setup %{user: user} do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:foreman, :github_app) end)

    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo, box: box, branch: "feature/x")
    stub(ClientMock, :installation_token, fn _, _ -> {:ok, "ghs_install"} end)
    %{env: env, box: box}
  end

  defp online(box), do: {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

  # Opens the page and answers the git status check it sends.
  defp open_with_status(conn, env, status) do
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    assert_receive {:dispatch, %{type: "env.git_status", op_id: op_id}}

    result =
      Map.merge(
        %{
          "branch" => "feature/x",
          "head" => @head,
          "base" => @head,
          "ahead" => 0,
          "changed_files" => 0,
          "unpushed_commits" => 0,
          "clean" => true
        },
        status
      )

    {:ok, op} = Operations.finish(op_id, "ok", result, nil)
    send(view.pid, {:operation, op})
    render_async(view)
    view
  end

  test "says how far behind and ahead the clone is", %{conn: conn, env: env, box: box} do
    online(box)

    expect(ClientMock, :compare, fn _, _, @head, "feature/x" ->
      {:ok, %{ahead_by: 3, behind_by: 2}}
    end)

    view = open_with_status(conn, env, %{"ahead" => 2})

    assert has_element?(view, "#branch-sync", "3 commits behind origin/feature/x")
    assert has_element?(view, "#branch-sync", "2 ahead")
  end

  test "says when the clone is up to date", %{conn: conn, env: env, box: box} do
    online(box)
    expect(ClientMock, :compare, fn _, _, _, _ -> {:ok, %{ahead_by: 0, behind_by: 0}} end)

    view = open_with_status(conn, env, %{})

    assert has_element?(view, "#branch-sync", "Up to date")
  end

  test "says when the clone has another branch checked out", %{conn: conn, env: env, box: box} do
    online(box)

    view = open_with_status(conn, env, %{"branch" => "topic"})

    assert has_element?(view, "#branch-sync", "topic checked out")
  end

  test "says nothing when GitHub can't compare", %{conn: conn, env: env, box: box} do
    online(box)
    expect(ClientMock, :compare, fn _, _, _, _ -> {:error, :not_found} end)

    view = open_with_status(conn, env, %{})

    refute has_element?(view, "#branch-sync")
  end

  test "the check isn't listed as activity", %{conn: conn, env: env, box: box} do
    online(box)
    stub(ClientMock, :compare, fn _, _, _, _ -> {:ok, %{ahead_by: 0, behind_by: 0}} end)

    view = open_with_status(conn, env, %{})

    refute has_element?(view, "#activity", "Check git status")
  end

  test "a check that's holding things up can still be cancelled", %{
    conn: conn,
    env: env,
    box: box
  } do
    online(box)
    {:ok, view, _html} = live(conn, ~p"/environments/#{env.id}")
    assert_receive {:dispatch, %{type: "env.git_status", op_id: check}}

    view |> element("button[phx-value-do=stop]") |> render_click()

    assert view |> element("#cancel-op") |> render() =~ check
  end

  test "a stopped environment isn't checked", %{conn: conn, user: user, box: box} do
    online(box)
    env = environment_fixture(user: user, box: box, observed_state: "stopped")

    {:ok, _view, _html} = live(conn, ~p"/environments/#{env.id}")

    refute_receive {:dispatch, %{type: "env.git_status"}}
  end

  test "the check runs again once a rebuild finishes", %{
    conn: conn,
    env: env,
    box: box,
    user: user
  } do
    online(box)
    stub(ClientMock, :compare, fn _, _, _, _ -> {:ok, %{ahead_by: 0, behind_by: 0}} end)
    view = open_with_status(conn, env, %{})

    stub(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
      {:ok, %{token: "ghu_scoped", expires_at: nil}}
    end)

    {:ok, op} = Foreman.Environments.rebuild(Foreman.Scope.for_user(user), env)
    assert_receive {:dispatch, %{type: "env.rebuild"}}
    render(view)
    refute_receive {:dispatch, %{type: "env.git_status"}}

    {:ok, op, env} =
      Operations.finish(op.id, "ok", %{}, nil, &Foreman.Environments.record_result/1)

    Foreman.Environments.after_result(op, env)
    render(view)

    assert_receive {:dispatch, %{type: "env.git_status"}}
  end
end
