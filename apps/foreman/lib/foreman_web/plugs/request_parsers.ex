defmodule ForemanWeb.Plugs.RequestParsers do
  @moduledoc "Parse the JSON resource API and render wire errors before a controller is reached."
  @behaviour Plug

  import Plug.Conn

  def init(options) do
    {Plug.Parsers.init(options),
     Plug.Parsers.init(Keyword.merge(options, parsers: [:json], pass: []))}
  end

  def call(conn, {options, json_options}) do
    case ForemanWeb.Plugs.OAuthTransport.policy(conn.path_info) do
      :resource -> parse_resource(conn, json_options)
      :relay -> parse_relay(conn)
      _ -> Plug.Parsers.call(conn, options)
    end
  end

  @relay_limit 2_000_000

  # A request a box relays (ForemanWeb.Plugs.RelayAuth). Its body is read
  # here once, whatever the method, so the bytes that are decoded are the
  # bytes whose digest the signature is checked against.
  #
  # One that can't be decoded isn't answered here. The box signed it, so
  # it is the environment's to answer for like any other: the refusal is
  # kept for RelayAuth, which counts the request first.
  defp parse_relay(conn) do
    conn = Phoenix.Controller.put_format(conn, "json")

    case ForemanWeb.Plugs.RelayBody.read(conn, @relay_limit) do
      {:ok, body, conn} ->
        decode_relay(conn, body)

      # No box sends one this large, and there is no digest to check a
      # signature against.
      {:too_large, conn} ->
        error(conn, 413, "request_too_large", "The request body exceeds the size limit.")

      {:error, conn} ->
        error(conn, 400, "invalid_request", "The request could not be read.")
    end
  end

  defp decode_relay(conn, body) do
    case relay_params(conn, body) do
      {:ok, body_params} ->
        conn = Plug.Conn.fetch_query_params(conn)
        %{conn | body_params: body_params, params: Map.merge(conn.query_params, body_params)}

      {:error, refusal} ->
        defer(conn, refusal)
    end
  rescue
    Plug.Conn.InvalidQueryError ->
      defer(conn, {400, "invalid_request", "The request could not be parsed."})
  end

  defp relay_params(_conn, ""), do: {:ok, %{}}

  defp relay_params(conn, body) do
    if get_req_header(conn, "content-type") == ["application/json"] do
      case Phoenix.json_library().decode(body) do
        {:ok, %{} = params} -> {:ok, params}
        {:ok, other} -> {:ok, %{"_json" => other}}
        {:error, _} -> {:error, {400, "invalid_request", "The request could not be parsed."}}
      end
    else
      {:error, {415, "unsupported_media_type", "Send the request body as application/json."}}
    end
  end

  defp defer(conn, refusal) do
    %{conn | body_params: %{}, params: %{}}
    |> put_private(:foreman_relay_refusal, refusal)
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
