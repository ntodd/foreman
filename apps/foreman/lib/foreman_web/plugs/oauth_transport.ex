defmodule ForemanWeb.Plugs.OAuthTransport do
  @moduledoc "Require a secure configured OAuth origin and a verified request scheme."
  import Plug.Conn
  alias ForemanWeb.ClientIP

  def init(opts), do: opts

  def call(conn, _) do
    case policy(conn.path_info) do
      :other -> conn
      _ -> secure(conn)
    end
  end

  @doc false
  def policy(["oauth" | _]), do: :oauth
  def policy(["api", "v1" | _]), do: :resource
  def policy([".well-known", "oauth-authorization-server"]), do: :oauth
  def policy(["admin", "apps" | _]), do: :oauth
  def policy(["settings", "connections" | _]), do: :oauth
  def policy(_), do: :other

  defp secure(conn) do
    uri = URI.parse(Foreman.Config.base_url())

    allowed =
      case uri do
        %URI{host: host, userinfo: nil, query: nil, fragment: nil, path: path}
        when is_binary(host) and host != "" and path in [nil, ""] ->
          case uri.scheme do
            "https" ->
              conn.scheme == :https

            "http" when host in ["127.0.0.1", "localhost", "::1"] ->
              ClientIP.loopback?(conn.remote_ip) and get_req_header(conn, "x-forwarded-for") == [] and
                get_req_header(conn, "x-forwarded-proto") == []

            _ ->
              false
          end

        _ ->
          false
      end

    if allowed do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(
        400,
        JSON.encode!(%{
          error: "invalid_request",
          error_description: "OAuth requires a secure instance origin and transport."
        })
      )
      |> halt()
    end
  end
end
