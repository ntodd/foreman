defmodule ForemanWeb.EnvironmentMutationControllerTest do
  use ForemanWeb.ConnCase

  import Foreman.PublicAPIMutationFixtures
  alias Foreman.{OAuth, Repo}
  setup :local_git
  setup %{conn: conn}, do: %{conn: %{conn | remote_ip: {127, 0, 0, 1}}}

  test "the authenticated routes return the operation location, stable state, errors and scopes",
       %{conn: conn} do
    user = user_fixture()
    repo = repo_fixture() |> Ecto.Changeset.change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    {actor, grant} = principal(user)
    full = OAuth.issue(grant, actor.scopes, :user).access_token
    limited = OAuth.issue(grant, ["environments:create"], :user).access_token

    submit = fn path, body, key, token ->
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", key)
      |> post(path, JSON.encode!(body))
    end

    base = "/api/v1/environments"
    created = submit.(base, %{repo_id: repo.id}, "create", full)
    assert %{"environment_id" => env, "operation_id" => op} = json_response(created, 202)
    assert get_resp_header(created, "location") == ["/api/v1/operations/#{op}"]
    actions = "#{base}/#{env}/operations"

    assert json_response(submit.(actions, %{action: "start"}, "follow", full), 202)[
             "operation_id"
           ] == op

    assert json_response(submit.(actions, %{action: "stop"}, "wait", full), 409)["code"] ==
             "lifecycle_conflict"

    assert json_response(submit.(actions, %{action: "destroy"}, "x", limited), 403)["code"] ==
             "insufficient_scope"

    assert json_response(submit.(actions, %{action: "stop", foo: 42}, "x", full), 422)["code"] ==
             "invalid_request"

    assert json_response(submit.(base, %{repo_id: repo.id, branch: "main"}, "create", full), 409)[
             "code"
           ] == "idempotency_conflict"

    assert json_response(submit.("#{base}/bad/operations", %{action: "stop"}, "x", full), 404)[
             "code"
           ] == "resource_not_found"

    {:ok, event} = ForemanProtocol.Event.new("op.result", %{op_id: op, status: "ok", result: %{}})
    :ok = Foreman.Agents.handle_event(box.id, event)
    stable = submit.(actions, %{action: "start"}, "stable", full)
    assert json_response(stable, 200) == %{"environment_id" => env}
    assert get_resp_header(stable, "location") == []
    Repo.delete!(Foreman.Operations.get!(op))
    replay = submit.(base, %{repo_id: repo.id}, "create", full)

    assert %{"environment_id" => ^env, "operation_id" => ^op, "operation_history_expired" => true} =
             json_response(replay, 202)

    assert get_resp_header(replay, "location") == ["/api/v1/operations/#{op}"]
  end

  test "invalid wire bodies return JSON errors that a headless client can decode", %{conn: conn} do
    {actor, grant} = principal(user_fixture())
    token = OAuth.issue(grant, actor.scopes, :user).access_token

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("idempotency-key", "wire")

    path = "/api/v1/environments"

    for {content_type, body, status, code} <- [
          {"application/x-www-form-urlencoded", "repo_id=invalid", 415, "unsupported_media_type"},
          {"application/json", "{", 400, "invalid_request"},
          {"application/json", String.duplicate(" ", 2_000_001), 413, "request_too_large"}
        ] do
      response = conn |> put_req_header("content-type", content_type) |> post(path, body)
      assert %{"code" => ^code, "message" => message} = json_response(response, status)
      assert is_binary(message)
    end
  end

  test "an unknown API route returns a machine-readable 404 without content negotiation", %{
    conn: conn
  } do
    {actor, grant} = principal(user_fixture())
    token = OAuth.issue(grant, actor.scopes, :user).access_token

    result =
      conn |> put_req_header("authorization", "Bearer " <> token) |> get("/api/v1/missing-route")

    assert %{"code" => "resource_not_found", "message" => _} = json_response(result, 404)
  end

  test "both mutations require a bearer credential", %{conn: conn} do
    for path <- [
          "/api/v1/environments",
          "/api/v1/environments/#{Ecto.UUID.generate()}/operations"
        ] do
      assert %{"code" => _, "message" => _} =
               conn |> post(path, %{}) |> json_response(401)
    end
  end
end
