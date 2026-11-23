defmodule ForemanWeb.OAuthTransportTest do
  use ForemanWeb.ConnCase

  setup do
    before = Application.fetch_env(:foreman, :base_url)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:foreman, :base_url, value)
        :error -> Application.delete_env(:foreman, :base_url)
      end
    end)

    :ok
  end

  test "use the configured HTTPS issuer over direct TLS or a trusted terminating proxy", %{
    conn: conn
  } do
    Application.put_env(:foreman, :base_url, "https://foreman.example.org")
    path = "/.well-known/oauth-authorization-server"
    direct = get(conn, "https://different.internal" <> path)
    assert json_response(direct, 200)["issuer"] == "https://foreman.example.org"
    proxy = %{conn | remote_ip: {127, 0, 0, 1}} |> put_req_header("x-forwarded-proto", "https")
    assert json_response(get(proxy, path), 200)["issuer"] == "https://foreman.example.org"
    remote = put_req_header(conn, "x-forwarded-proto", "https")
    assert get(remote, path).status == 400
    assert post(remote, "/oauth/token", %{grant_type: "client_credentials"}).status == 400
    assert get(conn, path).status == 400
  end

  test "remote HTTP origins are refused and loopback HTTP only serves a local peer", %{conn: conn} do
    path = "/.well-known/oauth-authorization-server"
    Application.put_env(:foreman, :base_url, "http://foreman.example.org")
    assert get(conn, "https://foreman.example.org" <> path).status == 400
    Application.put_env(:foreman, :base_url, "http://localhost:4000")
    assert get(conn, path).status == 400
    assert %{conn | remote_ip: {127, 0, 0, 1}} |> get(path) |> json_response(200)
  end
end
