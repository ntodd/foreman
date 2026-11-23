defmodule ForemanWeb.PublicReadControllerTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Operations, Repo}
  alias Foreman.Operations.LogStore
  alias ForemanWeb.PublicReadController

  @scopes ~w(repos:list boxes:list environments:list environments:read operations:list operations:read logs:read)

  setup do
    before = Application.get_env(:foreman, :git_base_url)
    Application.put_env(:foreman, :git_base_url, "https://git.example.test")

    on_exit(fn ->
      if before,
        do: Application.put_env(:foreman, :git_base_url, before),
        else: Application.delete_env(:foreman, :git_base_url)
    end)

    user = user_fixture()
    repo = repo_fixture() |> Ecto.Changeset.change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo, box: box, tailscale_device_id: "node123")
    env = Repo.update!(Ecto.Changeset.change(env, remote_user: "dev", workspace_folder: "/work"))

    {principal, _grant} = Foreman.PublicAPIMutationFixtures.principal(user, @scopes)

    %{principal: principal, env: env, repo: repo, box: box}
  end

  defp read(principal, action, params \\ %{}, status \\ 200) do
    conn = build_conn() |> assign(:api_principal, principal)
    json_response(apply(PublicReadController, action, [conn, params]), status)
  end

  defp op(env, attrs) do
    Map.merge(
      %{environment_id: env.id, box_id: env.box_id, action: "create", command: "env.create"},
      attrs
    )
    |> Operations.create!()
  end

  test "all seven routes require a bearer token and read through the actual service installation grants",
       ctx do
    admin = Foreman.Scope.for_user(user_fixture(role: "admin"))

    {:ok, installation} =
      Foreman.OAuth.ServiceAccounts.register(admin, "service", %{
        "name" => "automation",
        "scopes" => @scopes,
        "repo_ids" => [ctx.repo.id],
        "box_ids" => [ctx.box.id]
      })

    grant = installation.grant
    service = Repo.get!(Foreman.Accounts.User, grant.user_id)
    env = environment_fixture(user: service, repo: ctx.repo, box: ctx.box)
    op = op(env, %{status: "succeeded", finished_at: DateTime.utc_now()})
    %{access_token: token} = Foreman.OAuth.issue(grant, @scopes, :service_account)
    authed = fn -> put_req_header(build_conn(), "authorization", "Bearer " <> token) end

    for path <- [
          "/repos",
          "/boxes",
          "/environments",
          "/environments/#{env.id}",
          "/environments/#{env.id}/operations",
          "/operations/#{op.id}",
          "/operations/#{op.id}/logs"
        ] do
      url = "/api/v1" <> path
      assert json_response(get(build_conn(), url), 401)["code"] == "invalid_token"
      assert json_response(get(authed.(), url), 200)
    end

    assert json_response(get(authed.(), "/api/v1/environments/#{ctx.env.id}"), 404)["code"] ==
             "resource_not_found"

    Repo.update!(Ecto.Changeset.change(grant, box_ids: []))

    assert json_response(get(authed.(), "/api/v1/operations/#{op.id}/logs"), 404)["code"] ==
             "resource_not_found"
  end

  test "expiry and terminal timeout survive reads after a late success", ctx do
    at = DateTime.add(DateTime.utc_now(), 2, :day)
    Repo.update!(Ecto.Changeset.change(ctx.env, expiry_at: at, expiry_action: "stop"))

    assert read(ctx.principal, :environment, %{"id" => ctx.env.id})["expiry"] ==
             %{"at" => DateTime.to_iso8601(at), "action" => "stop"}

    op = op(ctx.env, %{status: "dispatched", dispatched_at: DateTime.utc_now()})
    {:ok, _} = Operations.timed_out(op, "no result")
    params = %{"id" => op.id}
    before = read(ctx.principal, :operation, params)
    assert %{"status" => "failed", "error" => %{"code" => "operation_timeout"}} = before
    assert {:ok, _} = Operations.finish(op.id, "ok", %{}, nil)
    assert read(ctx.principal, :operation, params) == before
  end

  test "discovery and environment lists only show accessible records and permitted fields", ctx do
    arbitrary = environment_fixture()
    env = ctx.env
    id = env.id

    assert %{"items" => [%{"id" => repo_id, "default_branch" => "main"}], "next_cursor" => nil} =
             read(ctx.principal, :repos)

    assert repo_id == ctx.repo.id
    assert %{"items" => [%{"id" => box_id, "online" => false}]} = read(ctx.principal, :boxes)
    assert box_id == ctx.box.id

    assert %{"items" => [%{"id" => ^id, "ssh_user" => "dev"}]} =
             read(ctx.principal, :environments)

    list_only = %{ctx.principal | scopes: ["environments:list"]}
    assert %{"items" => [row]} = read(list_only, :environments)
    refute Map.has_key?(row, "hostname")
    refute Map.has_key?(row, "ssh_user")
    refute Map.has_key?(row, "workspace_folder")
    assert %{"code" => _} = read(list_only, :environment, %{"id" => id}, 403)

    assert %{"code" => "resource_not_found"} =
             read(list_only, :environment, %{"id" => arbitrary.id}, 404)

    assert %{"code" => "resource_not_found"} =
             read(ctx.principal, :operation, %{"id" => "invalid"}, 404)

    assert %{"code" => "invalid_request"} =
             read(ctx.principal, :boxes, %{"cursor" => ["bad"]}, 422)
  end

  test "a destroyed environment retains authorized history, with individual log and history deadlines",
       ctx do
    env = ctx.env
    now = DateTime.utc_now()

    recent =
      op(env, %{
        action: "destroy",
        trigger: "expiry",
        status: "failed",
        error: "disk busy",
        finished_at: now
      })

    old_log = op(env, %{status: "succeeded", finished_at: DateTime.add(now, -31, :day)})
    expired = op(env, %{status: "succeeded", finished_at: DateTime.add(now, -91, :day)})
    Repo.update!(Ecto.Changeset.change(env, destroyed_at: now))

    assert read(ctx.principal, :environments)["items"] == []

    assert read(ctx.principal, :environment, %{"id" => env.id}, 404)["code"] ==
             "resource_not_found"

    ops = read(ctx.principal, :operations, %{"id" => env.id})["items"]
    assert Enum.sort(Enum.map(ops, & &1["id"])) == Enum.sort([recent.id, old_log.id])

    assert %{"action" => "destroy", "trigger" => "expiry", "error" => %{"message" => "disk busy"}} =
             read(ctx.principal, :operation, %{"id" => recent.id})

    assert read(ctx.principal, :operation, %{"id" => expired.id}, 404)["code"] ==
             "resource_not_found"

    assert read(ctx.principal, :logs, %{"id" => old_log.id}, 404)["code"] == "resource_not_found"

    assert %{"text" => "", "next_cursor" => cursor, "truncated" => false} =
             read(ctx.principal, :logs, %{"id" => recent.id})

    LogStore.append(recent.id, "next\n")

    assert %{"text" => "next\n"} =
             read(ctx.principal, :logs, %{"id" => recent.id, "cursor" => cursor})

    outsider = %{ctx.principal | user: user_fixture(), scopes: []}

    for {action, id} <- [operations: env.id, operation: recent.id, logs: recent.id] do
      assert read(outsider, action, %{"id" => id}, 404)["code"] == "resource_not_found"
      assert read(%{ctx.principal | scopes: []}, action, %{"id" => id}, 403)["code"]
    end
  end

  test "tied operation timestamps page without overlap and cursors are scoped to resource, grant and endpoint",
       ctx do
    now = DateTime.utc_now()
    rows = for _ <- 1..51, do: op(ctx.env, %{inserted_at: now})
    list = fn p, id, cursor -> read(p, :operations, %{"id" => id, "cursor" => cursor}) end

    assert %{"items" => first, "next_cursor" => cursor} =
             read(ctx.principal, :operations, %{"id" => ctx.env.id})

    assert is_binary(cursor)
    assert %{"items" => last, "next_cursor" => nil} = list.(ctx.principal, ctx.env.id, cursor)
    assert Enum.map(first ++ last, & &1["id"]) == Enum.sort(Enum.map(rows, & &1.id), :desc)
    other = environment_fixture(user: ctx.principal.user, repo: ctx.repo, box: ctx.box)

    {another_grant, _} = Foreman.PublicAPIMutationFixtures.principal(ctx.principal.user, @scopes)

    for {principal, action, params} <- [
          {ctx.principal, :operations, %{"id" => other.id}},
          {another_grant, :operations, %{"id" => ctx.env.id}},
          {ctx.principal, :logs, %{"id" => hd(rows).id}}
        ] do
      assert read(principal, action, Map.put(params, "cursor", cursor), 422)["code"] ==
               "invalid_request"
    end
  end
end
