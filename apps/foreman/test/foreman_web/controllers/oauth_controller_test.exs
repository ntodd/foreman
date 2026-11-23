defmodule ForemanWeb.OAuthControllerTest do
  use ForemanWeb.ConnCase
  import Ecto.Query
  alias Foreman.{Accounts, OAuth, Repo, Scope}
  alias Foreman.OAuth.{Device, Grant, Principal, ServiceAccounts, Token}

  @client "foreman-cli"
  @device "urn:ietf:params:oauth:grant-type:device_code"

  setup %{conn: conn}, do: %{conn: %{conn | remote_ip: {127, 0, 0, 1}}}

  defp post_form(conn, path, fields) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(fields))
  end

  defp begin_device(conn, client \\ @client) do
    conn
    |> post_form("/oauth/device/code", client_id: client, scope: "logs:read repos:list")
    |> json_response(200)
  end

  defp poll(conn, device, client \\ @client) do
    post_form(conn, "/oauth/token",
      grant_type: @device,
      client_id: client,
      device_code: device["device_code"]
    )
  end

  defp refresh(conn, token, extra \\ []),
    do:
      post_form(
        conn,
        "/oauth/token",
        [grant_type: "refresh_token", client_id: @client, refresh_token: token] ++ extra
      )

  defp consent(conn, user, device, choice) do
    conn
    |> log_in(user)
    |> post("/oauth/device", %{"decision" => choice, "user_code" => device["user_code"]})
    |> html_response(200)
  end

  defp personal_connection(conn, user) do
    device = begin_device(conn)
    consent(conn, user, device, "approve")
    tokens = poll(conn, device) |> json_response(200)
    {:ok, principal} = OAuth.authenticate(tokens["access_token"])
    {tokens, principal}
  end

  defp bearer(conn, raw),
    do: conn |> put_req_header("authorization", "Bearer " <> raw) |> get("/api/v1/me")

  defp basic(conn, id, secret),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64(id <> ":" <> secret))

  defp issue(conn, params \\ []),
    do: post_form(conn, "/oauth/token", [grant_type: "client_credentials"] ++ params)

  defp expired, do: DateTime.add(DateTime.utc_now(), -1)

  test "polling respects per-code deadlines, slowdown and single-use consent", %{conn: conn} do
    device = begin_device(conn)
    assert device["expires_in"] == 600
    assert device["interval"] == 5
    assert json_response(poll(conn, device), 400)["error"] == "authorization_pending"
    assert json_response(poll(conn, device), 400)["error"] == "slow_down"
    assert Repo.one!(Device).interval == 10
    consent(conn, user_fixture(), device, "approve")

    assert post(log_in(conn, user_fixture()), "/oauth/device", %{
             "decision" => "deny",
             "user_code" => device["user_code"]
           }).status == 400

    Repo.update_all(Device, set: [poll_after: expired()])
    issued = poll(conn, device)
    assert get_resp_header(issued, "cache-control") == ["no-store"]
    assert get_resp_header(issued, "pragma") == ["no-cache"]

    assert %{"expires_in" => 900, "scope" => "logs:read repos:list", "token_type" => "Bearer"} =
             json_response(issued, 200)

    assert json_response(poll(conn, device), 400)["error"] == "invalid_grant"
    Repo.update_all(Device, set: [expires_at: expired()])
    assert json_response(poll(conn, device), 400)["error"] == "expired_token"
  end

  test "approval is bound to the registered client and displayed scopes", %{conn: conn} do
    admin = user_fixture(role: "admin") |> Scope.for_user()
    {:ok, %{client: app}} = ServiceAccounts.register(admin, "public", %{"name" => "Build tool"})
    device = begin_device(conn, app.id)

    assert redirected_to(get(conn, "/oauth/device?user_code=" <> device["user_code"])) ==
             "/sign-in"

    assert json_response(poll(conn, device), 400)["error"] == "invalid_grant"
    user = user_fixture()

    page =
      conn
      |> log_in(user)
      |> get("/oauth/device", %{user_code: device["user_code"]})
      |> html_response(200)

    assert page =~ "Build tool"
    assert page =~ "logs:read"
    consent(conn, user, device, "deny")
    assert json_response(poll(conn, device, app.id), 400)["error"] == "access_denied"

    assert json_response(
             post_form(conn, "/oauth/device/code", client_id: @client, scope: "admin"),
             400
           )["error"] == "invalid_scope"

    device = begin_device(conn, app.id)
    consent(conn, user, device, "approve")
    tokens = json_response(poll(conn, device, app.id), 200)
    assert json_response(refresh(conn, tokens["refresh_token"]), 400)["error"] == "invalid_grant"
    assert {:ok, :disabled} = ServiceAccounts.disable(admin, app.id)
    assert bearer(conn, tokens["access_token"]).status == 401
  end

  test "refresh rotates under one grant, narrows the access token, and detects replay", %{
    conn: conn
  } do
    {old, principal} = personal_connection(conn, user_fixture())

    assert json_response(refresh(conn, old["refresh_token"], scope: "environments:destroy"), 400)[
             "error"
           ] == "invalid_scope"

    new = refresh(conn, old["refresh_token"], scope: "logs:read") |> json_response(200)
    refute new["refresh_token"] == old["refresh_token"]
    assert {:ok, %Principal{scopes: ["logs:read"]}} = OAuth.authenticate(new["access_token"])
    assert {:ok, ^principal} = OAuth.authorize_grant(principal.grant_id)
    assert json_response(refresh(conn, old["refresh_token"]), 400)["error"] == "invalid_grant"
    assert bearer(conn, new["access_token"]).status == 401
    assert json_response(refresh(conn, new["refresh_token"]), 400)["error"] == "invalid_grant"
    assert OAuth.authorize_grant(principal.grant_id) == :error
  end

  test "access expiry and refresh inactivity are separate deadlines, renewed only by refresh", %{
    conn: conn
  } do
    {old, principal} = personal_connection(conn, user_fixture())
    grant = Repo.get!(Grant, principal.grant_id)
    assert_in_delta DateTime.diff(grant.expires_at, DateTime.utc_now()), 90 * 86_400, 2
    Repo.update_all(from(t in Token, where: t.kind == "access"), set: [expires_at: expired()])
    assert bearer(conn, old["access_token"]).status == 401
    near = DateTime.add(DateTime.utc_now(), 30)
    Repo.update_all(Grant, set: [expires_at: near])
    new = refresh(conn, old["refresh_token"]) |> json_response(200)

    assert_in_delta DateTime.diff(Repo.reload!(grant).expires_at, DateTime.utc_now()),
                    90 * 86_400,
                    2

    Repo.update_all(Grant, set: [expires_at: DateTime.utc_now()])
    assert OAuth.authorize_grant(grant.id) == :error
    assert json_response(refresh(conn, new["refresh_token"]), 400)["error"] == "invalid_grant"
  end

  test "grant management and logout affect only the selected connection", %{conn: conn} do
    owner = user_fixture()
    {first, p1} = personal_connection(conn, owner)
    {other, p2} = personal_connection(conn, owner)
    assert %Principal{kind: :user, user: %{id: id}, client_id: @client} = p1
    assert id == owner.id
    assert bearer(conn, first["access_token"]).assigns.api_principal == p1

    assert %{"id" => ^id, "kind" => "user", "client_id" => @client} =
             json_response(bearer(conn, first["access_token"]), 200)

    assert get(log_in(conn, owner), "/settings/connections").resp_body =~ "Foreman CLI"
    path = "/settings/connections/#{p1.grant_id}/revoke"
    assert post(log_in(conn, user_fixture()), path).status == 404
    assert post(log_in(conn, owner), path).status == 302
    assert bearer(conn, first["access_token"]).status == 401
    assert bearer(conn, other["access_token"]).status == 200

    assert post_form(conn, "/oauth/revoke", token: other["refresh_token"], client_id: @client).status ==
             200

    assert post_form(conn, "/oauth/revoke", token: "unknown", client_id: @client).status == 200
    assert OAuth.authorize_grant(p2.grant_id) == :error
  end

  test "local disable immediately revokes bearer, refresh, unexchanged approval and queued authority permanently",
       %{conn: conn} do
    user = user_fixture()
    admin = user_fixture(role: "admin") |> Scope.for_user()
    {tokens, p} = personal_connection(conn, user)
    pending = begin_device(conn)
    consent(conn, user, pending, "approve")
    {:ok, disabled} = Accounts.set_disabled(admin, user, true)
    assert bearer(conn, tokens["access_token"]).status == 401
    assert OAuth.authorize_grant(p.grant_id) == :error
    {:ok, _} = Accounts.set_disabled(admin, disabled, false)
    assert bearer(conn, tokens["access_token"]).status == 401
    assert json_response(refresh(conn, tokens["refresh_token"]), 400)["error"] == "invalid_grant"
    assert json_response(poll(conn, pending), 400)["error"] == "invalid_grant"
  end

  test "service identity has explicit resource grants and survives the installer's departure", %{
    conn: conn
  } do
    installer = user_fixture(role: "admin")
    scope = Scope.for_user(installer)
    repo = repo_fixture() |> Ecto.Changeset.change(github_id: 882) |> Repo.update!()
    box = box_fixture(owner_user_id: installer.id)
    secret = secret_fixture("repo", repo, "BUILD_KEY", "test", actor: installer)

    attrs = %{
      "name" => "Team CI",
      "scopes" => ~w(repos:list environments:create),
      "repo_ids" => [repo.id],
      "box_ids" => [box.id],
      "secret_ids" => [secret.id],
      "tailscale_tags" => ["tag:ci"]
    }

    {:ok, %{client: client, secret: raw, grant: grant}} =
      ServiceAccounts.register(scope, "service", attrs)

    other = user_fixture(role: "admin") |> Scope.for_user()
    assert {:ok, _} = Accounts.set_disabled(other, installer, true)
    assert issue(conn, client_id: client.id, client_secret: raw).status == 401
    assert issue(basic(conn, client.id, "incorrect")).status == 401
    assert issue(basic(conn, client.id, raw), client_id: client.id).status == 401

    assert json_response(issue(basic(conn, client.id, raw), scope: "logs:read"), 400)["error"] ==
             "invalid_scope"

    auth = basic(conn, client.id, raw)
    service = json_response(issue(auth, scope: "repos:list"), 200)
    refute Map.has_key?(service, "refresh_token")

    assert {:ok, %Principal{kind: :service_account, scopes: ["repos:list"]} = p} =
             OAuth.authenticate(service["access_token"])

    assert p.user.id != installer.id and p.user.service_account
    assert {:ok, full} = ServiceAccounts.principal_for_user(p.user.id)
    assert full.grant_id == grant.id
    assert full.scopes == attrs["scopes"]
    assert [repo.id] == ServiceAccounts.repo_ids(p)
    assert [box.id] == ServiceAccounts.box_ids(p)
    assert [secret.id] == ServiceAccounts.secret_ids(p)

    assert %{"tailscale_tags" => ["tag:foreman-svc-" <> _, "tag:ci"]} =
             ServiceAccounts.network_policy(p)

    assert is_nil(Accounts.create_session(p.user, "browser"))
    assert Accounts.access(p.user) == :denied

    assert {:error, :not_allowed} =
             Accounts.sign_in_from_github(%{"id" => 99, "login" => p.user.login}, %{},
               config: %{admins: [p.user.login], allowed_users: [], allowed_org: nil}
             )

    assert Repo.reload!(client).secret_hash != raw

    another = json_response(issue(auth), 200)
    assert post_form(auth, "/oauth/revoke", token: service["access_token"]).status == 200
    assert bearer(conn, service["access_token"]).status == 401
    assert bearer(conn, another["access_token"]).status == 200
    {:ok, %{secret: rotated}} = ServiceAccounts.rotate(other, client.id)
    assert issue(auth).status == 401
    assert bearer(conn, another["access_token"]).status == 401
    new = json_response(issue(basic(conn, client.id, rotated)), 200)
    assert {:ok, :disabled} = ServiceAccounts.disable(other, client.id)
    assert issue(basic(conn, client.id, rotated)).status == 401
    assert bearer(conn, new["access_token"]).status == 401
    assert OAuth.authorize_grant(grant.id) == :error
    assert ServiceAccounts.principal_for_user(p.user.id) == :error
    assert [] == ServiceAccounts.repo_ids(p)
    assert is_nil(ServiceAccounts.network_policy(p))
    assert [%Grant{revoked_at: %DateTime{}}] = ServiceAccounts.installations(other)
  end

  test "admin-only registration and one-time disclosure protect installation credentials", %{
    conn: conn
  } do
    member = log_in(conn, user_fixture())
    assert get(member, "/admin/apps").status == 404
    assert post(member, "/admin/apps", %{kind: "public", name: "X"}).status == 404
    admin = log_in(conn, user_fixture(role: "admin"))
    form = %{kind: "service", name: "Build", scopes: ["repos:list"]}

    for bad <- [
          %{scopes: ["invalid"]},
          %{box_ids: [Ecto.UUID.generate()]},
          %{secret_ids: ["bad"]},
          %{tailscale_tags: ["bad"]}
        ] do
      assert post(admin, "/admin/apps", Map.merge(form, bad)).status == 422
    end

    created = post(admin, "/admin/apps", form)
    assert created.status == 200
    assert created.resp_body =~ "Save this credential now"
    assert get_resp_header(created, "cache-control") == ["no-store"]
    refute get(admin, "/admin/apps").resp_body =~ "Save this credential now"
  end
end
