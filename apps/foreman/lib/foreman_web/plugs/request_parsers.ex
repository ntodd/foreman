defmodule ForemanWeb.Plugs.RequestParsers do
  @moduledoc "Parse the JSON resource API and render wire errors before a controller is reached."
  @behaviour Plug

  import Plug.Conn

  def init(options) do
    {Plug.Parsers.init(options),
     Plug.Parsers.init(Keyword.merge(options, parsers: [:json], pass: []))}
  end

  def call(conn, {options, json_options}) do
    if ForemanWeb.Plugs.OAuthTransport.policy(conn.path_info) == :resource,
      do: parse_resource(conn, json_options),
      else: Plug.Parsers.call(conn, options)
  end

  defp parse_resource(conn, json_options) do
    conn = Phoenix.Controller.put_format(conn, "json")
    Plug.Parsers.call(conn, json_options)
  rescue
    Plug.Parsers.UnsupportedMediaTypeError ->
      error(conn, 415, "unsupported_media_type", "Send the request body as application/json.")

    Plug.Parsers.RequestTooLargeError ->
      error(conn, 413, "request_too_large", "The request body exceeds the size limit.")

    _error in [Plug.Parsers.ParseError, Plug.Conn.InvalidQueryError] ->
      error(conn, 400, "invalid_request", "The request could not be parsed.")
  end

  defp error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{code: code, message: message}))
    |> halt()
  end
end
