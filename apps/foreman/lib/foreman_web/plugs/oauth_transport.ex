defmodule ForemanWeb.Plugs.OAuthTransport do
  @moduledoc "Require a secure configured OAuth origin and a verified request scheme."
  import Plug.Conn
  alias ForemanWeb.ClientIP

  def init(opts), do: opts

  def call(%{path_info: ["oauth" | _]} = conn, _), do: secure(conn)
  def call(%{path_info: ["api", "v1" | _]} = conn, _), do: secure(conn)

  def call(%{path_info: [".well-known", "oauth-authorization-server"]} = conn, _),
    do: secure(conn)

  def call(%{path_info: ["admin", "apps" | _]} = conn, _), do: secure(conn)
  def call(%{path_info: ["settings", "connections" | _]} = conn, _), do: secure(conn)
  def call(conn, _), do: conn

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
