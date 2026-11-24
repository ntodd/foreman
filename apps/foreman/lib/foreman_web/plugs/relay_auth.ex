defmodule ForemanWeb.Plugs.RelayAuth do
  @moduledoc """
  Authenticates a public API request a box relays for one of its
  environments (`Foreman.OAuth.EnvironmentConnection`).

  The box signs each request with its enrolled key (`ForemanProtocol.Auth`),
  over the environment, the method as sent, the target, the body and the
  idempotency key or the lack of one. A request is refused unless the
  signature is the box's, fresh and never accepted before, the request
  that would run is the one that was sent, and the environment is live
  on that box. Every refusal reads the same, so a box
  learns nothing about an environment that isn't its own.

  A body is JSON and says so: the signature covers its bytes, and the
  content type decides whether they are parsed at all.

  No bearer token is read here: a token gives nothing on these routes,
  and a relay signature gives nothing on the ordinary ones.

  Two kinds of limit, kept apart so neither can be turned on a third
  party. Requests that aren't signed by any box count against the
  address they came from, as refused agent connects do (and as there,
  an address sending many of them is refused until it stops). Requests
  a box did sign count against that box's allowance for that
  environment first, then the box's own, before anything is looked up
  or written for them and whether or not they are then allowed. One
  environment can spend its own allowance and a fraction of its box's,
  and a box can't spend an allowance for an environment on another's
  account: the allowance is the box's that signed.
  """
  import Plug.Conn

  alias Foreman.Agents.RelayNonce
  alias Foreman.OAuth.EnvironmentConnection
  alias Foreman.RateLimit
  alias ForemanProtocol.Auth
  alias ForemanWeb.ClientIP
  alias ForemanWeb.Plugs.RelayBody

  require Logger

  @max_failures 600
  @window 60_000
  # One environment's share, far above what a person or an agent at a
  # terminal sends, and a box's across all of its environments: ten
  # environments' worth, so no one of them can use it up.
  @max_requests 600
  @max_box_requests 6_000
  @empty :crypto.hash(:sha256, "")

  def init(opts), do: opts

  def call(conn, _opts) do
    ip = ClientIP.from_conn(conn)
    key = "relay-failed:#{ip}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, digest} <- RelayBody.digest(conn),
         {:ok, signed} <- verify(conn, digest) do
      admit(conn, signed)
    else
      true ->
        if RateLimit.failed(key, @window, @max_failures) == :first_over,
          do: Logger.warning("relayed requests from #{ip} are rate limited")

        unauthorized(conn)

      reason ->
        RateLimit.failed(key, @window, @max_failures)
        Logger.warning("refused a relayed request from #{ip}: #{inspect(reason)}")
        unauthorized(conn)
    end
  end

  # Signed by a box, so it's that box's and that environment's to answer
  # for from here on.
  defp admit(conn, signed) do
    box = signed.agent_id
    box_key = "relay-box:#{box}"

    # A box that has used its allowance is turned away before a counter is
    # made for whatever environment it names next.
    with false <- RateLimit.exhausted?(box_key, @window, @max_box_requests),
         {:allow, _} <-
           RateLimit.hit("relay:#{box}:#{signed.environment}", @window, @max_requests),
         {:allow, _} <- RateLimit.hit(box_key, @window, @max_box_requests),
         :ok <- as_sent(conn),
         :ok <- readable(conn),
         :ok <- json_body(conn, signed.body_sha256),
         :ok <- RelayNonce.claim(signed.nonce, signed.ts),
         {:ok, principal} <- EnvironmentConnection.principal(box, signed.environment) do
      conn
      |> assign(:api_principal, principal)
      |> assign(:relay_box_id, box)
    else
      limited when limited == true or elem(limited, 0) == :deny ->
        refuse(conn, :too_many_requests, "rate_limited", "Too many requests. Try again shortly.")

      {:refuse, {status, code, message}} ->
        refuse(conn, status, code, message)

      _ ->
        unauthorized(conn)
    end
  end

  # A body the parsers couldn't decode (ForemanWeb.Plugs.RequestParsers
  # kept the refusal for here). The box signed it and it has been counted,
  # so the environment is told what was wrong with it.
  defp readable(conn) do
    case conn.private[:foreman_relay_refusal] do
      nil -> :ok
      refusal -> {:refuse, refusal}
    end
  end

  # A method override in the body, or HEAD's turn into GET, makes the
  # request that would run a different one from the one the box signed.
  # Checked here and not before the signature: the box did sign it, so the
  # refusal is the environment's to answer for and not the address's.
  defp as_sent(conn) do
    if conn.private[:foreman_wire_method] == conn.method, do: :ok, else: {:error, :method}
  end

  defp verify(conn, digest) do
    with {:ok, headers} <- signing_headers(conn),
         {:ok, key} <- idempotency_key(conn),
         {:ok, method} <- wire_method(conn) do
      with {:ok, signed} <-
             Auth.verify_relay_headers(headers, &Foreman.Boxes.public_key/1, %{
               method: method,
               target: target(conn),
               body_sha256: digest,
               idempotency_key: key
             }),
           do: {:ok, Map.put(signed, :body_sha256, digest)}
    end
  end

  # A header sent twice has no one value to check.
  defp signing_headers(conn) do
    names = Auth.relay_header_names()
    headers = for {name, value} <- conn.req_headers, name in names, do: {name, value}

    if length(Enum.uniq_by(headers, &elem(&1, 0))) == length(headers),
      do: {:ok, Map.new(headers)},
      else: {:error, :malformed}
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [] -> {:ok, nil}
      [key] -> {:ok, key}
      _ -> {:error, :malformed}
    end
  end

  # The parsers read a body as JSON only when it says it is one. Bytes
  # that are signed and then not parsed would be a request with no input.
  # Checked once the signature has been: a box that signed it answers for
  # it, like any other request it signed.
  defp json_body(_conn, @empty), do: :ok

  defp json_body(conn, _digest) do
    case get_req_header(conn, "content-type") do
      ["application/json"] -> :ok
      _ -> {:error, :malformed}
    end
  end

  # What the box sent and signed, before a method override or HEAD's turn
  # into GET.
  defp wire_method(conn) do
    case conn.private[:foreman_wire_method] do
      method when is_binary(method) -> {:ok, method}
      _ -> {:error, :malformed}
    end
  end

  defp target(%{query_string: ""} = conn), do: conn.request_path
  defp target(conn), do: conn.request_path <> "?" <> conn.query_string

  defp unauthorized(conn) do
    refuse(
      conn,
      :unauthorized,
      "invalid_request_signature",
      "A request signed by the environment's box is required."
    )
  end

  defp refuse(conn, status, code, message) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{code: code, message: message})
    |> halt()
  end
end
