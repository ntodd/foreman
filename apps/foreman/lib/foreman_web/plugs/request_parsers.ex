defmodule ForemanWeb.Plugs.RequestParsers do
  @moduledoc "Parse the JSON resource API and render wire errors before a controller is reached."
  @behaviour Plug

  import Plug.Conn

  def init(options) do
    {Plug.Parsers.init(options),
     Plug.Parsers.init(Keyword.merge(options, parsers: [:json], pass: []))}
  end

  def call(%{path_info: ["api", "v1" | _]} = conn, {_, json_options}) do
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

  def call(conn, {options, _}), do: Plug.Parsers.call(conn, options)

  defp error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{code: code, message: message}))
    |> halt()
  end
end
