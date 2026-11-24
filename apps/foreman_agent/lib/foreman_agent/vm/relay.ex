defmodule ForemanAgent.VM.Relay do
  @moduledoc """
  Public API requests from inside an environment's VM, relayed to the
  control plane by the box.

  The VM asks with an `api` frame on its link (`ForemanAgent.Channel`).
  The box decides which environment the request is for: the one whose
  link the frame arrived on, never anything the frame says. It checks the
  request, signs it with its own key for that environment
  (`ForemanProtocol.Auth.relay_headers/4`) and sends it to the control
  plane's relay mount of the public API, where it can do what that
  environment's own connection may and nothing more.

  The VM is hostile, so `request/1` passes very little:

    * `GET`, `POST` and `PATCH`, the methods the API uses
    * a target under `/api/v1/`, of plain path segments (no dots alone,
      no encoding, no empty segment) and a plain query. The box prefixes
      the relay's mount, so the target is checked to be exactly a path
      under it.
    * a body on a change only, as text, up to `max_body/0` bytes
    * an idempotency key, of printable characters

  No header of the VM's reaches the control plane but that key, which is
  signed with the rest. The answer goes back as a status, a body and the
  two headers a client acts on (`location`, `retry-after`).

  The box relays over HTTPS, or to a control plane on its own loopback.
  Over plain HTTP to anywhere else it refuses unless
  `FOREMAN_RELAY_INSECURE` is set: nothing vouches for the answer there.
  """

  alias ForemanAgent.{Config, Identity}
  alias ForemanProtocol.Auth

  require Logger

  @prefix "/api/v1"
  @mount "/api/agents/relay/v1"
  @methods ~w(GET POST PATCH)
  @changes ~w(POST PATCH)
  # A segment is letters, digits and the few marks an id, a scope or a
  # login can hold, starting with a letter or a digit: never "." or "..".
  @path ~r/\A(?:\/[A-Za-z0-9][A-Za-z0-9._~-]*)+\z/
  @query ~r/\A(?:[A-Za-z0-9._~=&+-]|%[0-9A-Fa-f]{2})*\z/
  @key ~r/\A[\x21-\x7E]{1,255}\z/
  @max_path 1024
  @max_query 2048
  # The link carries a megabyte from the VM; this leaves room for the rest
  # of the frame.
  @max_body 900_000
  # And four to it.
  @max_reply 3_000_000
  @max_id 9_007_199_254_740_991
  @timeout 30_000
  @passed_back ~w(location retry-after)

  @type request :: %{
          method: String.t(),
          path: String.t(),
          query: String.t() | nil,
          body: binary(),
          key: String.t() | nil
        }
  @type reply :: %{status: 100..599, body: binary(), headers: %{String.t() => String.t()}}

  def max_body, do: @max_body
  def max_reply, do: @max_reply
  def timeout, do: @timeout

  @doc "The request an `api` frame asks for, or `:error` for one the box won't send."
  @spec request(map()) :: {:ok, request()} | :error
  def request(%{"id" => id, "method" => method, "target" => target} = frame)
      when is_integer(id) and id >= 0 and id <= @max_id and method in @methods and
             is_binary(target) do
    with {:ok, path, query} <- target(target),
         {:ok, body} <- body(method, frame["body"]),
         {:ok, key} <- key(method, frame["idempotency_key"]) do
      {:ok, %{method: method, path: path, query: query, body: body, key: key}}
    end
  end

  def request(_frame), do: :error

  defp target(@prefix <> rest) do
    {path, query} =
      case String.split(rest, "?", parts: 2) do
        [path] -> {path, nil}
        [path, query] -> {path, query}
      end

    # An empty query is none: the control plane can't tell "/me?" from
    # "/me", and the target the box signs is the one it will see.
    query = if query == "", do: nil, else: query

    if byte_size(path) <= @max_path and Regex.match?(@path, path) and
         not String.contains?(path, "..") and query?(query),
       do: {:ok, path, query},
       else: :error
  end

  defp target(_other), do: :error

  defp query?(nil), do: true
  defp query?(query), do: byte_size(query) <= @max_query and Regex.match?(@query, query)

  defp body(_method, nil), do: {:ok, ""}
  defp body(_method, ""), do: {:ok, ""}

  defp body(method, body)
       when method in @changes and is_binary(body) and byte_size(body) <= @max_body,
       do: {:ok, body}

  defp body(_method, _body), do: :error

  defp key(_method, nil), do: {:ok, nil}

  defp key(method, key) when method in @changes and is_binary(key),
    do: if(Regex.match?(@key, key), do: {:ok, key}, else: :error)

  defp key(_method, _key), do: :error

  @doc """
  Sends a checked request to the control plane for `env_id`, and returns
  its answer. Anything that goes wrong on the way is an answer too, in
  the API's own error shape, so a client shows it like any other.

  Options: `:identity` and `:url` (default: this box's), `:req_options`
  (merged into the request), `:timeout`.
  """
  @spec forward(String.t(), request(), keyword()) :: reply()
  def forward(env_id, request, opts \\ []) do
    with %Identity{} = identity <- identity(opts),
         {:ok, url} <- url(opts),
         :ok <- transport(url, opts) do
      send_request(env_id, request, identity, url, opts)
    else
      :insecure -> insecure()
      _ -> failed("This box isn't connected to a control plane.")
    end
  end

  # The signature keeps a request from being changed or sent again. It
  # says nothing for the answer, which a client in the environment will
  # act on, and a body's secrets are in the clear without TLS. So the box
  # relays over HTTPS, or to itself, and otherwise only when told to
  # (`FOREMAN_RELAY_INSECURE`), on a network its operator trusts.
  defp transport(url, opts) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        :ok

      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost", "::1"] ->
        :ok

      %URI{scheme: "http", host: host} when is_binary(host) and host != "" ->
        if Keyword.get_lazy(opts, :insecure, fn -> Config.get().relay_insecure end),
          do: :ok,
          else: :insecure

      _ ->
        :insecure
    end
  end

  defp identity(opts) do
    case Keyword.fetch(opts, :identity) do
      {:ok, identity} ->
        identity

      :error ->
        case Identity.load(Config.get().data_dir) do
          {:ok, identity} -> identity
          _ -> nil
        end
    end
  end

  defp url(opts) do
    case Keyword.get_lazy(opts, :url, fn -> Config.get().url end) do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> :error
    end
  end

  defp send_request(env_id, request, identity, url, opts) do
    target = @mount <> request.path <> if(request.query, do: "?" <> request.query, else: "")

    signed =
      Auth.relay_headers(identity.agent_id, identity.private_key, %{
        environment: env_id,
        method: request.method,
        target: target,
        body: request.body,
        idempotency_key: request.key
      })

    headers =
      Map.to_list(signed) ++
        [{"accept", "application/json"}, {"user-agent", "foreman-agent/#{Identity.version()}"}] ++
        if(request.body == "", do: [], else: [{"content-type", "application/json"}]) ++
        if(request.key, do: [{"idempotency-key", request.key}], else: [])

    options =
      [
        method: request.method,
        url: url <> target,
        headers: headers,
        body: request.body,
        # The answer is the control plane's, passed on as it came: one
        # attempt, no redirect followed, nothing decoded.
        retry: false,
        redirect: false,
        decode_body: false,
        compressed: false,
        receive_timeout: Keyword.get(opts, :timeout, @timeout),
        into: &collect/2
      ] ++ Keyword.get(opts, :req_options, [])

    case Req.request(options) do
      {:ok, response} -> answer(response)
      {:error, error} -> unreachable(error)
    end
  rescue
    # A field the signature can't cover. `request/1` passes none.
    ArgumentError -> invalid()
  end

  # Kept to what a reply frame can carry; the rest is never read.
  defp collect({:data, data}, {request, response}) do
    size = Req.Response.get_private(response, :relay_size, 0) + byte_size(data)

    if size > @max_reply do
      {:halt, {request, Req.Response.put_private(response, :relay_over, true)}}
    else
      chunks = Req.Response.get_private(response, :relay_chunks, [])

      response =
        response
        |> Req.Response.put_private(:relay_size, size)
        |> Req.Response.put_private(:relay_chunks, [data | chunks])

      {:cont, {request, response}}
    end
  end

  defp answer(response) do
    body =
      response
      |> Req.Response.get_private(:relay_chunks, [])
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    cond do
      Req.Response.get_private(response, :relay_over, false) ->
        failed("The control plane's answer was too large to pass on.")

      not String.valid?(body) ->
        failed("The control plane's answer couldn't be passed on.")

      true ->
        %{status: response.status, body: body, headers: passed_back(response)}
    end
  end

  defp passed_back(response) do
    for name <- @passed_back,
        [value | _] <- [Req.Response.get_header(response, name)],
        byte_size(value) <= 2048 and String.printable?(value),
        into: %{},
        do: {name, value}
  end

  defp unreachable(error) do
    Logger.warning("couldn't relay an API request: #{Exception.message(error)}")
    failed("The box couldn't reach the control plane. Try again shortly.")
  end

  @doc "The answer to a frame `request/1` refused."
  def invalid,
    do: error(400, "invalid_relay_request", "The box won't relay this request.")

  @doc "The answer when the VM already has as many requests in flight as it may."
  def busy,
    do: error(429, "relay_busy", "Too many requests at once. Try again shortly.")

  @doc "The answer when the control plane took too long."
  def timed_out,
    do: error(504, "relay_timeout", "The control plane took too long to answer.")

  defp insecure do
    error(
      502,
      "relay_insecure_transport",
      "This box reaches its control plane over plain HTTP, so it doesn't relay API requests."
    )
  end

  @doc "The answer when relaying failed on the box."
  def failed(message \\ "The box couldn't relay the request."),
    do: error(502, "relay_failed", message)

  defp error(status, code, message),
    do: %{status: status, body: JSON.encode!(%{code: code, message: message}), headers: %{}}
end
