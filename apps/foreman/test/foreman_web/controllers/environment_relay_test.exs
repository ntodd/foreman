defmodule ForemanWeb.EnvironmentRelayTest do
  @moduledoc """
  The public API as a box relays it for one of its environments: signed by
  the box for each request, and limited to that environment.
  """
  use ForemanWeb.ConnCase

  import Foreman.PublicAPIMutationFixtures
  import Ecto.Query

  alias Foreman.{Agents.NonceCache, OAuth, Repo, Scope, Secrets}
  alias ForemanProtocol.Auth

  @prefix "/api/agents/relay/v1"

  setup :local_git

  setup do
    user = user_fixture()
    repo = repo_fixture() |> Ecto.Changeset.change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    env = environment_fixture(user: user, repo: repo, box: box)
    sibling = environment_fixture(user: user, repo: repo, box: box)

    %{user: user, repo: repo, box: box, env: env, sibling: sibling}
  end

  # What a box sends: the request, and headers signed over exactly it.
  defp signed(conn, box, env_id, method, path, body, opts \\ []) do
    raw = if body, do: JSON.encode!(body), else: ""
    target = @prefix <> path

    headers =
      Auth.relay_headers(
        box.id,
        Keyword.get(opts, :key, box.__private_key__),
        %{
          environment: env_id,
          method: method,
          target: target,
          body: raw,
          idempotency_key: opts[:idempotency_key]
        },
        Keyword.take(opts, [:now])
      )

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
    {conn, target, raw}
  end

  defp send_request({conn, target, raw}, method),
    do: dispatch(conn, @endpoint, method, target, if(raw == "", do: nil, else: raw))

  defp relay(ctx, method, path, body \\ nil, opts \\ []) do
    env_id = Keyword.get(opts, :env, ctx.env.id)
    box = Keyword.get(opts, :box, ctx.box)

    ctx.conn
    |> maybe_key(opts[:idempotency_key])
    |> signed(box, env_id, method, path, body, opts)
    |> send_request(method)
  end

  defp maybe_key(conn, nil), do: conn
  defp maybe_key(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp refused(conn) do
    assert %{"code" => "invalid_request_signature"} = json_response(conn, 401)
    conn
  end

  describe "a request the environment's box signed" do
    test "is the environment's owner, and says which environment it is", ctx do
      me = json_response(relay(ctx, "GET", "/me"), 200)

      assert me["id"] == ctx.user.id
      assert me["name"] == ctx.user.login
      assert me["kind"] == "user"
      assert me["client_id"] == "foreman-environment"
      assert me["environment"] == %{"id" => ctx.env.id, "name" => ctx.env.slug}
    end

    test "comes from wherever the box is, with no transport rule of its own", ctx do
      refute ctx.conn.remote_ip == {127, 0, 0, 1}
      assert json_response(relay(ctx, "GET", "/me"), 200)
    end

    test "lists and reads that environment and no other", ctx do
      assert %{"items" => [%{"id" => id}], "next_cursor" => nil} =
               json_response(relay(ctx, "GET", "/environments"), 200)

      assert id == ctx.env.id
      assert json_response(relay(ctx, "GET", "/environments/#{ctx.env.id}"), 200)["id"] == id

      assert json_response(relay(ctx, "GET", "/environments/#{ctx.sibling.id}"), 404)
      assert json_response(relay(ctx, "GET", "/environments/#{ctx.sibling.id}/operations"), 404)
    end

    test "lists neither repositories nor boxes", ctx do
      assert json_response(relay(ctx, "GET", "/repos"), 403)
      assert json_response(relay(ctx, "GET", "/boxes"), 403)
    end

    test "sets and lists the environment's own secrets, with a query string", ctx do
      path = "/secrets/environment/#{ctx.env.id}"

      changed = relay(ctx, "PATCH", path, %{secrets: [%{name: "TOKEN", value: "s3cret value"}]})
      assert %{"set" => ["TOKEN"]} = json_response(changed, 200)
      refute changed.resp_body =~ "s3cret value"
      assert Secrets.resolve(ctx.env) == %{"TOKEN" => "s3cret value"}

      assert %{"items" => [%{"name" => "TOKEN"}]} =
               json_response(relay(ctx, "GET", path <> "?limit=10"), 200)
    end

    test "reaches no secrets but its own", ctx do
      admin = user_fixture(role: "admin")
      box = box_fixture(owner_user_id: admin.id)
      env = environment_fixture(user: admin, repo: ctx.repo, box: box)
      other = environment_fixture(user: admin, repo: ctx.repo, box: box)

      {:ok, _} =
        Secrets.put_secret(Scope.for_user(admin), "user", admin, %{
          "name" => "MINE",
          "value" => "1"
        })

      as_admin = fn method, path, body ->
        relay(ctx, method, path, body, box: box, env: env.id)
      end

      body = %{secrets: [%{name: "X", value: "1"}]}

      for path <- [
            "/secrets/user/me",
            "/secrets/user/#{admin.id}",
            "/secrets/repo/#{ctx.repo.id}",
            "/secrets/owner/#{ctx.repo.owner.login}"
          ] do
        assert json_response(as_admin.("GET", path, nil), 403)["message"] =~
                 "manages that environment's secrets only"

        assert json_response(as_admin.("PATCH", path, body), 403)["message"] =~
                 "manages that environment's secrets only"
      end

      assert json_response(as_admin.("GET", "/secrets/environment/#{other.id}", nil), 404)
      assert json_response(as_admin.("PATCH", "/secrets/environment/#{other.id}", body), 404)
      assert Secrets.resolve(other) == %{"MINE" => "1"}
    end

    test "a start that can't be admitted doesn't describe the box", ctx do
      Repo.update!(
        Ecto.Changeset.change(ctx.env, desired_state: "stopped", observed_state: "stopped")
      )

      actions = "/environments/#{ctx.env.id}/operations"

      # The box is offline: its owner is told which box, the environment isn't.
      reply = relay(ctx, "POST", actions, %{action: "start"}, idempotency_key: "s1")
      body = json_response(reply, 409)
      assert body["code"] == "start_unavailable"
      refute body["message"] =~ ctx.box.name
      refute body["message"] =~ "offline"
    end

    test "stops the environment, and can't destroy it or create another", ctx do
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
      actions = "/environments/#{ctx.env.id}/operations"

      stopped = relay(ctx, "POST", actions, %{action: "stop"}, idempotency_key: "r1")
      assert %{"operation_id" => op} = json_response(stopped, 202)
      assert is_binary(op)
      assert get_resp_header(stopped, "location") == ["/api/v1/operations/#{op}"]
      assert json_response(relay(ctx, "GET", "/operations/#{op}"), 200)["action"] == "stop"

      destroy = relay(ctx, "POST", actions, %{action: "destroy"}, idempotency_key: "d1")
      assert json_response(destroy, 403)["code"] == "insufficient_scope"

      create = relay(ctx, "POST", "/environments", %{repo_id: ctx.repo.id}, idempotency_key: "c1")
      assert json_response(create, 404)["code"] == "resource_not_found"

      other = "/environments/#{ctx.sibling.id}/operations"
      stop = relay(ctx, "POST", other, %{action: "stop"}, idempotency_key: "s1")
      assert json_response(stop, 404)["code"] == "resource_not_found"

      assert Repo.get!(Foreman.Environments.Environment, ctx.env.id).destroyed_at == nil
    end
  end

  describe "a request is refused" do
    test "when the box doesn't run that environment", ctx do
      other_box = box_fixture(owner_user_id: ctx.user.id)
      refused(relay(ctx, "GET", "/me", nil, box: other_box))

      stranger = environment_fixture()
      refused(relay(ctx, "GET", "/me", nil, env: stranger.id))
      refused(relay(ctx, "GET", "/me", nil, env: Ecto.UUID.generate()))
    end

    test "when the environment is destroyed, or the box revoked", ctx do
      assert json_response(relay(ctx, "GET", "/me"), 200)

      Repo.update!(Ecto.Changeset.change(ctx.env, destroyed_at: DateTime.utc_now()))
      refused(relay(ctx, "GET", "/me"))

      Repo.update!(Ecto.Changeset.change(ctx.env, destroyed_at: nil))
      Repo.update!(Ecto.Changeset.change(ctx.box, revoked_at: DateTime.utc_now()))
      refused(relay(ctx, "GET", "/me"))
    end

    test "when it's signed by another key, or stale", ctx do
      {_public, other} = Auth.generate_keypair()
      refused(relay(ctx, "GET", "/me", nil, key: other))
      refused(relay(ctx, "GET", "/me", nil, now: System.os_time(:second) - 120))
    end

    test "when it's sent a second time", ctx do
      request = signed(ctx.conn, ctx.box, ctx.env.id, "GET", "/me", nil)

      assert json_response(send_request(request, "GET"), 200)
      refused(send_request(request, "GET"))
    end

    test "when the body, the path, the query, the method or the environment was changed", ctx do
      path = "/secrets/environment/#{ctx.env.id}"
      body = %{secrets: [%{name: "A", value: "signed"}]}
      {conn, target, _raw} = signed(ctx.conn, ctx.box, ctx.env.id, "PATCH", path, body)

      forged = JSON.encode!(%{secrets: [%{name: "A", value: "forged"}]})
      refused(dispatch(conn, @endpoint, "PATCH", target, forged))

      {conn, target, raw} = signed(ctx.conn, ctx.box, ctx.env.id, "PATCH", path, body)
      elsewhere = String.replace(target, ctx.env.id, ctx.sibling.id)
      refused(dispatch(conn, @endpoint, "PATCH", elsewhere, raw))

      {conn, target, _raw} = signed(ctx.conn, ctx.box, ctx.env.id, "GET", path, nil)
      refused(dispatch(conn, @endpoint, "GET", target <> "?limit=1", nil))

      {conn, target, _raw} = signed(ctx.conn, ctx.box, ctx.env.id, "GET", path, nil)
      refused(dispatch(conn, @endpoint, "PATCH", target, nil))

      {conn, target, _raw} = signed(ctx.conn, ctx.box, ctx.env.id, "GET", "/me", nil)

      refused(
        conn
        |> put_req_header("x-foreman-environment", ctx.sibling.id)
        |> dispatch(@endpoint, "GET", target, nil)
      )

      assert Secrets.resolve(ctx.env) == %{}
    end

    test "when a body arrives that the signature says is empty", ctx do
      {conn, target, _raw} = signed(ctx.conn, ctx.box, ctx.env.id, "GET", "/me", nil)

      refused(
        conn
        |> put_req_header("content-type", "text/plain")
        |> dispatch(@endpoint, "GET", target, "unsigned")
      )
    end

    test "when it has no signature, whatever else it carries", ctx do
      {actor, grant} = principal(ctx.user, OAuth.Scopes.all())
      token = OAuth.issue(grant, actor.scopes, :user).access_token

      refused(get(ctx.conn, @prefix <> "/me"))

      refused(
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("x-foreman-environment", ctx.env.id)
        |> get(@prefix <> "/me")
      )
    end

    test "when a connect signature is sent in a relay's place", ctx do
      headers =
        ctx.box.id
        |> Auth.connect_headers(ctx.box.__private_key__)
        |> Map.put("x-foreman-environment", ctx.env.id)

      conn = Enum.reduce(headers, ctx.conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
      refused(get(conn, @prefix <> "/me"))
    end
  end

  describe "what the signature covers beyond the request line and body" do
    test "the idempotency key: another, or none, is a different request", ctx do
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
      path = "/environments/#{ctx.env.id}/operations"
      body = %{action: "stop"}

      {conn, target, raw} =
        signed(ctx.conn, ctx.box, ctx.env.id, "POST", path, body, idempotency_key: "mine")

      refused(
        conn
        |> put_req_header("idempotency-key", "theirs")
        |> dispatch(@endpoint, "POST", target, raw)
      )

      # Signed with a key, sent with none.
      {conn, target, raw} =
        signed(ctx.conn, ctx.box, ctx.env.id, "POST", path, body, idempotency_key: "mine")

      refused(dispatch(conn, @endpoint, "POST", target, raw))

      # Signed with none, sent with one.
      {conn, target, raw} = signed(ctx.conn, ctx.box, ctx.env.id, "POST", path, body)

      refused(
        conn
        |> put_req_header("idempotency-key", "added")
        |> dispatch(@endpoint, "POST", target, raw)
      )

      # Sent twice, there's no one key to check.
      {conn, target, raw} =
        signed(ctx.conn, ctx.box, ctx.env.id, "POST", path, body, idempotency_key: "mine")

      twice = %{
        conn
        | req_headers: conn.req_headers ++ [{"idempotency-key", "mine"}, {"idempotency-key", "x"}]
      }

      refused(dispatch(twice, @endpoint, "POST", target, raw))

      assert Repo.get!(Foreman.Environments.Environment, ctx.env.id).desired_state == "running"
    end

    test "a body is JSON and says so, or the request is refused", ctx do
      path = "/secrets/environment/#{ctx.env.id}"
      body = %{secrets: [%{name: "A", value: "1"}]}

      for type <- ["text/plain", "application/x-www-form-urlencoded", "application/json; x=1"] do
        {conn, target, raw} = signed(ctx.conn, ctx.box, ctx.env.id, "PATCH", path, body)
        conn = put_req_header(conn, "content-type", type)

        reply = dispatch(conn, @endpoint, "PATCH", target, raw)
        assert reply.status in [401, 415]
      end

      assert Secrets.resolve(ctx.env) == %{}
    end

    test "the method as it was sent: a HEAD isn't the GET that was signed", ctx do
      {conn, target, _raw} = signed(ctx.conn, ctx.box, ctx.env.id, "GET", "/me", nil)
      assert dispatch(conn, @endpoint, "HEAD", target, nil).status == 401

      # It was refused before its nonce was spent: the request itself is still good.
      assert json_response(dispatch(conn, @endpoint, "GET", target, nil), 200)
    end

    test "a body that names another method changes nothing", ctx do
      path = "/environments/#{ctx.env.id}/operations"
      body = %{"_method" => "PATCH", "action" => "stop"}

      # The router has no such route for the method the body names, and the
      # request isn't the one that was signed either way.
      reply = relay(ctx, "POST", path, body, idempotency_key: "m1")
      assert reply.status in [401, 404, 422]
      assert Repo.get!(Foreman.Environments.Environment, ctx.env.id).desired_state == "running"
    end

    # The box signed it as it was sent, so it is the environment's to answer
    # for: refused, and not counted against the address its box shares with
    # every other environment on it.
    test "one environment can't spend its box's good name with such bodies", ctx do
      path = "/secrets/environment/#{ctx.env.id}"
      body = %{"_method" => "PATCH", "secrets" => [%{"name" => "A", "value" => "1"}]}

      import ExUnit.CaptureLog

      capture_log(fn ->
        statuses = for _ <- 1..700, do: relay(ctx, "POST", path, body).status
        assert Enum.all?(statuses, &(&1 in [401, 429]))
      end)

      assert Secrets.resolve(ctx.env) == %{}
      assert json_response(relay(ctx, "GET", "/me", nil, env: ctx.sibling.id), 200)
    end
  end

  describe "a request sent again" do
    test "is refused after the control plane restarts, too", ctx do
      request = signed(ctx.conn, ctx.box, ctx.env.id, "GET", "/me", nil)
      assert json_response(send_request(request, "GET"), 200)

      # What a restart leaves of anything kept in memory.
      :ets.delete_all_objects(NonceCache)

      refused(send_request(request, "GET"))
    end

    test "spent nonces are cleared once their requests are too old to be accepted", ctx do
      request = signed(ctx.conn, ctx.box, ctx.env.id, "GET", "/me", nil)
      assert json_response(send_request(request, "GET"), 200)
      assert Repo.aggregate(Foreman.Agents.RelayNonce, :count) == 1

      Foreman.Agents.RelayNonce.prune(DateTime.add(DateTime.utc_now(), 300))
      assert Repo.aggregate(Foreman.Agents.RelayNonce, :count) == 0
    end
  end

  describe "an owner who lost access" do
    test "has no connection made for their environments again", ctx do
      assert json_response(relay(ctx, "GET", "/me"), 200)

      Foreman.Accounts.revoke_access(Repo.reload!(ctx.user), "left the organization")

      refused(relay(ctx, "GET", "/me"))
      refused(relay(ctx, "GET", "/environments/#{ctx.env.id}"))

      live =
        Repo.all(
          from g in Foreman.OAuth.Grant,
            where: g.environment_id == ^ctx.env.id and is_nil(g.revoked_at)
        )

      assert live == []
    end
  end

  describe "one environment asking too much" do
    test "is slowed itself, and its box's other environments aren't", ctx do
      within_one_window()

      statuses =
        for _ <- 1..620, do: relay(ctx, "GET", "/environments/#{ctx.env.id}").status

      assert Enum.take(statuses, 500) |> Enum.uniq() == [200]
      assert List.last(statuses) == 429

      assert json_response(relay(ctx, "GET", "/me", nil, env: ctx.sibling.id), 200)
    end

    test "another box can't spend its allowance for it", ctx do
      other = box_fixture(owner_user_id: ctx.user.id)

      import ExUnit.CaptureLog

      capture_log(fn ->
        statuses = for _ <- 1..620, do: relay(ctx, "GET", "/me", nil, box: other).status
        assert Enum.uniq(Enum.take(statuses, 600)) == [401]
      end)

      assert json_response(relay(ctx, "GET", "/me"), 200)
    end

    test "a body that can't be read as what it says it is counts like any other request", ctx do
      within_one_window()

      path = "/secrets/environment/#{ctx.env.id}"
      target = @prefix <> path
      broken = ~s({"secrets": [)

      send_broken = fn ->
        headers =
          Auth.relay_headers(ctx.box.id, ctx.box.__private_key__, %{
            environment: ctx.env.id,
            method: "PATCH",
            target: target,
            body: broken
          })

        headers
        |> Enum.reduce(ctx.conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, "PATCH", target, broken)
      end

      # The box signed it, so the environment is told what was wrong with it.
      assert json_response(send_broken.(), 400)["code"] == "invalid_request"

      # And it is the environment's to answer for, not something free to send.
      statuses = for _ <- 1..620, do: send_broken.().status
      assert List.last(statuses) == 429
      assert json_response(relay(ctx, "GET", "/me", nil, env: ctx.sibling.id), 200)

      # Unsigned, the same body says nothing about itself.
      unsigned =
        ctx.conn
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, "PATCH", target, broken)

      import ExUnit.CaptureLog
      capture_log(fn -> refused(unsigned) end)
    end

    test "a box that has used its own allowance is refused before any more is counted", ctx do
      within_one_window()

      key = "relay-box:#{ctx.box.id}"
      for _ <- 1..6_000, do: Foreman.RateLimit.hit(key, 60_000, 6_000)
      before = :ets.info(Foreman.RateLimit, :size)

      for _ <- 1..20 do
        reply = relay(ctx, "GET", "/me", nil, env: Ecto.UUID.generate())
        assert json_response(reply, 429)["code"] == "rate_limited"
      end

      # No counter was made for any of the environments it named.
      assert :ets.info(Foreman.RateLimit, :size) == before
    end

    test "an environment that has no connection can't use up its box's allowance", ctx do
      Repo.update!(Ecto.Changeset.change(ctx.sibling, destroyed_at: DateTime.utc_now()))

      import ExUnit.CaptureLog

      capture_log(fn ->
        for _ <- 1..700, do: relay(ctx, "GET", "/me", nil, env: ctx.sibling.id)
      end)

      assert json_response(relay(ctx, "GET", "/me"), 200)
    end
  end

  test "a relay signature opens nothing on the ordinary API", ctx do
    conn = %{ctx.conn | remote_ip: {127, 0, 0, 1}}

    headers =
      Auth.relay_headers(ctx.box.id, ctx.box.__private_key__, %{
        environment: ctx.env.id,
        method: "GET",
        target: "/api/v1/me",
        body: ""
      })

    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    assert json_response(get(conn, "/api/v1/me"), 401)["code"] == "invalid_token"
  end

  test "an ordinary connection's identity names no environment", ctx do
    {actor, grant} = principal(ctx.user, OAuth.Scopes.all())
    token = OAuth.issue(grant, actor.scopes, :user).access_token

    me =
      %{ctx.conn | remote_ip: {127, 0, 0, 1}}
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/v1/me")
      |> json_response(200)

    refute Map.has_key?(me, "environment")
  end

  test "the environment's client can't be used to ask for a token", ctx do
    reply =
      %{ctx.conn | remote_ip: {127, 0, 0, 1}}
      |> post("/oauth/device/code", %{client_id: "foreman-environment"})

    assert reply.status in [400, 401]
    assert Repo.aggregate(Foreman.OAuth.Device, :count) == 0
  end

  test "a nonce is remembered, so the cache is what refuses a replay" do
    nonce = "relay-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    assert NonceCache.check(nonce) == :ok
    assert NonceCache.check(nonce) == :replay
  end
end
