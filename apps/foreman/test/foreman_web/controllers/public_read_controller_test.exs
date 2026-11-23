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

  test "start returns a readable Location when a dashboard rebuild already targets running",
       ctx do
    rebuild = op(ctx.env, %{action: "rebuild", command: "env.rebuild", status: "running"})
    internal = op(ctx.env, %{action: "secrets_write", command: "env.secrets.write"})
    scopes = ["environments:start", "operations:read", "operations:list", "logs:read"]
    {_, grant} = Foreman.PublicAPIMutationFixtures.principal(ctx.principal.user, scopes)
    token = Foreman.OAuth.issue(grant, scopes, :user).access_token
    authed = fn -> put_req_header(build_conn(), "authorization", "Bearer " <> token) end
    history = "/api/v1/environments/#{ctx.env.id}/operations"

    res =
      authed.()
      |> put_req_header("idempotency-key", "follow")
      |> post(history, %{action: "start"})

    assert json_response(res, 202)["operation_id"] == rebuild.id
    [location] = get_resp_header(res, "location")
    assert json_response(get(authed.(), location), 200)["action"] == "rebuild"
    assert json_response(get(authed.(), location <> "/logs"), 200)["text"] == ""

    assert Enum.map(json_response(get(authed.(), history), 200)["items"], & &1["id"]) == [
             rebuild.id
           ]

    assert json_response(get(authed.(), "/api/v1/operations/#{internal.id}"), 404)
  end

  test "late agent messages cannot reopen logs or extend terminal history", ctx do
    for days <- [31, 91] do
      deadline = DateTime.add(DateTime.utc_now(), -days, :day)

      op =
        op(ctx.env, %{
          status: "failed",
          timeout_error: "expired",
          error: "expired",
          args: %{"timed_out" => true},
          finished_at: deadline
        })

      id = %{"id" => op.id}
      LogStore.append(op.id, "old output")
      assert read(ctx.principal, :logs, id, 404)

      for {type, fields} <- [
            {"op.accepted", %{}},
            {"op.log", %{stream: "stdout", data: "late output\n"}},
            {"op.result", %{status: "error", error: "cancelled"}},
            {"op.result", %{status: "ok"}},
            {"op.result", %{status: "error", error: "duplicate"}}
          ] do
        {:ok, event} = ForemanProtocol.Event.new(type, Map.put(fields, :op_id, op.id))
        assert :ok = Foreman.Agents.handle_event(ctx.box.id, event)
        assert Operations.get!(op.id).finished_at == deadline
      end

      assert read(ctx.principal, :logs, id, 404)
      assert read(ctx.principal, :operation, id, if(days == 31, do: 200, else: 404))
      assert :ok = Foreman.Jobs.Housekeeping.perform(%{})

      if days == 31,
        do: assert({"", 0, false} == LogStore.page(op, 0)),
        else: refute(Operations.get(op.id))
    end
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

  test "upgrading settles reopened timeouts without changing the environment or its history",
       ctx do
    first = DateTime.add(DateTime.utc_now(), -60)

    legacy =
      op(ctx.env, %{
        status: "running",
        args: %{"timed_out" => true},
        error: "first timeout",
        finished_at: first,
        dispatched_at: DateTime.add(first, -7200)
      })

    active = op(ctx.env, %{status: "running", dispatched_at: first})
    migration = Foreman.Repo.Migrations.SettleReopenedTimeouts
    version = 20_261_123_030_001
    opts = [log: false, migration_lock: false]

    Code.require_file(
      Path.join(
        :code.priv_dir(:foreman),
        "repo/migrations/#{version}_settle_reopened_timeouts.exs"
      )
    )

    assert :ok = Ecto.Migrator.down(Repo, version, migration, opts)
    assert :ok = Ecto.Migrator.up(Repo, version, migration, opts)

    assert %{
             status: "failed",
             timeout_error: "first timeout",
             error: "first timeout",
             finished_at: ^first
           } = Operations.get!(legacy.id)

    assert Repo.reload!(ctx.env) == ctx.env
    assert Operations.get!(active.id) == active

    params = %{"id" => legacy.id}
    before = read(ctx.principal, :operation, params)
    assert %{"status" => "failed", "error" => %{"code" => "operation_timeout"}} = before

    assert {:ok, %{status: "succeeded", finished_at: ^first}} =
             Operations.finish(legacy.id, "ok", %{}, nil)

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
