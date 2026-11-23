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

  test "client address forwarding and TLS termination have independent authorities", %{conn: conn} do
    Application.put_env(:foreman, :base_url, "https://foreman.example.org")
    cache = {ForemanWeb.ClientIP, :trusted}
    previous = :persistent_term.get(cache, nil)
    :persistent_term.put(cache, ForemanWeb.ClientIP.parse_trusted(["192.0.2.10"]))
    before = Application.fetch_env(:foreman, :tls_proxy_ranges)

    Application.put_env(
      :foreman,
      :tls_proxy_ranges,
      ForemanWeb.ClientIP.parse_trusted(["192.0.2.20"])
    )

    on_exit(fn ->
      if previous, do: :persistent_term.put(cache, previous), else: :persistent_term.erase(cache)

      case before do
        {:ok, value} -> Application.put_env(:foreman, :tls_proxy_ranges, value)
        :error -> Application.delete_env(:foreman, :tls_proxy_ranges)
      end
    end)

    forwarded =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.1")
      |> put_req_header("x-forwarded-proto", "https")

    ip_proxy = %{forwarded | remote_ip: {192, 0, 2, 10}}
    tls_proxy = %{forwarded | remote_ip: {192, 0, 2, 20}}
    assert ForemanWeb.ClientIP.from_conn(ip_proxy) == "203.0.113.1"
    assert ForemanWeb.ClientIP.from_conn(tls_proxy) == "192.0.2.20"
    assert get(ip_proxy, "/.well-known/oauth-authorization-server").status == 400
    assert get(tls_proxy, "/.well-known/oauth-authorization-server").status == 200
  end

  test "the browser login uses the same TLS terminators as OAuth", %{conn: conn} do
    before = Application.fetch_env(:foreman, :force_ssl)
    Application.put_env(:foreman, :force_ssl, true)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:foreman, :force_ssl, value)
        :error -> Application.delete_env(:foreman, :force_ssl)
      end
    end)

    forwarded = put_req_header(conn, "x-forwarded-proto", "https")
    assert get(forwarded, "http://foreman.example.org/sign-in").status == 301

    assert get(%{forwarded | remote_ip: {127, 0, 0, 1}}, "http://foreman.example.org/sign-in").scheme ==
             :https
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
