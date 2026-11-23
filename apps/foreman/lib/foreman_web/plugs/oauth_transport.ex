defmodule ForemanWeb.Plugs.OAuthTransport do
  @moduledoc "Require a secure configured OAuth origin and a verified request scheme."
  import Plug.Conn
  alias ForemanWeb.ClientIP

  def init(opts), do: opts

  def call(conn, _) do
    case policy(conn.path_info) do
      :other -> conn
      policy -> secure(conn, policy)
    end
  end

  @doc false
  # Phoenix.Router dispatches on URI.decode/1 applied once to each segment.
  def policy(path_info), do: path_info |> Enum.map(&URI.decode/1) |> route_policy()

  defp route_policy(["oauth" | _]), do: :oauth
  defp route_policy(["api", "v1" | _]), do: :resource
  defp route_policy([".well-known", "oauth-authorization-server"]), do: :oauth
  defp route_policy(["admin", "apps" | _]), do: :oauth
  defp route_policy(["settings", "connections" | _]), do: :oauth
  defp route_policy(_), do: :other

  defp secure(conn, policy) do
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
      |> send_resp(400, JSON.encode!(transport_error(policy)))
      |> halt()
    end
  end

  defp transport_error(:resource),
    do: %{
      code: "insecure_transport",
      message: "The API requires a secure instance origin and transport."
    }

  defp transport_error(:oauth),
    do: %{
      error: "invalid_request",
      error_description: "OAuth requires a secure instance origin and transport."
    }
end
