defmodule ForemanAgent.Guest.API do
  @moduledoc """
  The public API, from inside an environment.

  Listens on `api.sock` in the environment's directory under the secrets
  root, which its devcontainer already has at `/run/foreman`, and speaks
  plain HTTP/1.1 there: `foreman` in the container, or `curl
  --unix-socket`, asks for `/api/v1/…` as it would of the control plane.
  Each request goes to the box over the VM's link as one `api` frame
  (`ForemanAgent.Guest.Session.request/3`), and the box sends it on as
  this environment and no other (`ForemanAgent.VM.Relay`). There is no
  token here to send or to steal: which environment is asking is the
  box's to say.

  The socket is the mode the secrets beside it are, so whoever can read
  them can ask. What's asked is the environment's own (anything in it can
  already read those secrets), so this end only keeps itself standing: a
  request has a size and a time to arrive in, a connection carries one
  request, and only so many are served at once. Deciding what may be
  asked is the box's job, and the control plane's after it.

  Of the client's headers only `Idempotency-Key` is passed on.

  Options:

    * `:root` - the secrets root (default: the config's)
    * `:relay` - `fn request -> {:ok, reply} | {:error, reason} end`
      (default: `ForemanAgent.Guest.Server.request/1`)
    * `:max_connections` - clients served at once (default 16)
    * `:read_timeout` - milliseconds a request has to arrive (default 10 s)
  """
  use GenServer

  alias ForemanAgent.Guest

  require Logger

  @socket "api.sock"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  # What a frame to the box can carry (`ForemanAgent.VM.Relay.max_body/0`).
  @max_body 900_000
  @max_headers 64
  @max_line 8_192
  @max_target 4_096
  @max_connections 16
  @read_timeout 10_000
  # How long a client that has its answer is read from before the close.
  @linger 1_000
  # How long before listening is tried again after it failed.
  @relisten_after 5_000
  @passed_back ~w(location retry-after)

  @reasons %{
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    204 => "No Content",
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    408 => "Request Timeout",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    413 => "Content Too Large",
    415 => "Unsupported Media Type",
    422 => "Unprocessable Content",
    429 => "Too Many Requests",
    500 => "Internal Server Error",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Timeout"
  }

  def max_body, do: @max_body
  def max_headers, do: @max_headers

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Listens for `env_id`'s containers, if it isn't already. `:error` for an
  id that isn't one, or a socket that can't be made.
  """
  @spec ensure(GenServer.server(), term()) :: :ok | :error
  def ensure(api \\ __MODULE__, env_id) do
    if is_binary(env_id) and Regex.match?(@uuid, env_id),
      do: GenServer.call(api, {:ensure, env_id}),
      else: :error
  catch
    # Not running: this isn't a guest, or it's on its way down.
    :exit, _ -> :error
  end

  @impl true
  def init(opts) do
    state = %{
      root: Keyword.get_lazy(opts, :root, fn -> ForemanAgent.Config.get().secrets_root end),
      relay: Keyword.get(opts, :relay, &Guest.Server.request/1),
      max_connections: Keyword.get(opts, :max_connections, @max_connections),
      read_timeout: Keyword.get(opts, :read_timeout, @read_timeout),
      # env_id => {listening socket, the process accepting on it}
      listeners: %{},
      # monitor => true, one for each client being served
      clients: %{},
      # monitor => env_id, one for each acceptor
      acceptors: %{}
    }

    # An agent that restarted still has its environments' directories;
    # their containers shouldn't wait for the next command to ask again.
    # One that can't be listened for just now is tried again: nothing else
    # would, for an environment that gets no command.
    {:ok, Enum.reduce(existing(state.root), state, &relisten(&2, &1))}
  end

  defp existing(root) do
    case File.ls(root) do
      {:ok, names} ->
        Enum.filter(names, &(Regex.match?(@uuid, &1) and kind(Path.join(root, &1)) == :directory))

      {:error, _} ->
        []
    end
  end

  # What a path is itself, never what a link at it points to. A socket is
  # told from a FIFO or anything else "other" by its mode.
  defp kind(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :other, mode: mode}} ->
        if Bitwise.band(mode, 0o170000) == 0o140000, do: :socket, else: :other

      {:ok, %File.Stat{type: type}} ->
        type

      {:error, :enoent} ->
        :none

      {:error, _} ->
        :unreadable
    end
  end

  @impl true
  def handle_call({:ensure, env_id}, _from, state) do
    if listening?(state, env_id) do
      {:reply, :ok, state}
    else
      {result, state} = listen(state, env_id)
      {:reply, result, state}
    end
  end

  # An acceptor asks for a place for the client it just accepted, before
  # anything is read from it or any process exists for it. With none
  # free, the acceptor hangs up.
  def handle_call(:reserve, _from, state) do
    if map_size(state.clients) < state.max_connections do
      ctx = Map.take(state, [:relay, :read_timeout])
      {pid, monitor} = spawn_monitor(fn -> client(ctx) end)
      {:reply, {:ok, pid}, %{state | clients: Map.put(state.clients, monitor, true)}}
    else
      {:reply, :full, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.acceptors, monitor) do
      # Nothing accepts for this environment any more. Listen again now:
      # an environment that is otherwise idle may get no command for hours.
      {env_id, acceptors} when is_binary(env_id) ->
        {socket, listeners} = pop_listener(state.listeners, env_id, monitor)
        if socket, do: :gen_tcp.close(socket)
        state = %{state | acceptors: acceptors, listeners: listeners}
        {:noreply, relisten(state, env_id)}

      {nil, _} ->
        {:noreply, %{state | clients: Map.delete(state.clients, monitor)}}
    end
  end

  def handle_info({:relisten, env_id}, state) do
    if Map.has_key?(state.listeners, env_id),
      do: {:noreply, state},
      else: {:noreply, relisten(state, env_id)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Only while the environment's directory is still there, and again in a
  # while if it can't be done now.
  defp relisten(state, env_id) do
    if kind(Path.dirname(path(state, env_id))) == :directory do
      case listen(state, env_id) do
        {:ok, state} ->
          state

        {:error, state} ->
          Process.send_after(self(), {:relisten, env_id}, @relisten_after)
          state
      end
    else
      state
    end
  end

  # Only the listener this acceptor served: a newer one may have taken
  # its place already.
  defp pop_listener(listeners, env_id, monitor) do
    case listeners do
      %{^env_id => {socket, _pid, ^monitor}} -> {socket, Map.delete(listeners, env_id)}
      _ -> {nil, listeners}
    end
  end

  # Something is accepting, and its socket is still where clients look
  # for it: the directory can be made again under a listener.
  defp listening?(state, env_id) do
    case state.listeners do
      %{^env_id => {_socket, pid, _monitor}} ->
        Process.alive?(pid) and kind(path(state, env_id)) == :socket

      _ ->
        false
    end
  end

  defp path(state, env_id), do: Path.join([state.root, env_id, @socket])

  defp listen(state, env_id) do
    path = path(state, env_id)
    dir = Path.dirname(path)
    state = forget(state, env_id)

    with :ok <- own_directory(dir),
         :ok <- clear(path),
         {:ok, socket} <- :gen_tcp.listen(0, listen_opts(path)),
         :ok <- private(socket, path) do
      api = self()
      {pid, monitor} = spawn_monitor(fn -> accept(socket, api) end)

      {:ok,
       %{
         state
         | listeners: Map.put(state.listeners, env_id, {socket, pid, monitor}),
           acceptors: Map.put(state.acceptors, monitor, env_id)
       }}
    else
      error ->
        Logger.warning("couldn't listen for the public API at #{path}: #{inspect(error)}")
        {:error, state}
    end
  end

  defp forget(state, env_id) do
    case Map.pop(state.listeners, env_id) do
      {{socket, _pid, monitor}, listeners} ->
        Process.demonitor(monitor, [:flush])
        :gen_tcp.close(socket)
        %{state | listeners: listeners, acceptors: Map.delete(state.acceptors, monitor)}

      {nil, _} ->
        state
    end
  end

  # The environment's own directory, itself: made if it isn't there, and
  # never a link to somewhere else, whose mode this would change and
  # where the socket would land.
  defp own_directory(dir) do
    # The root is the agent's own configuration. Only the last step is the
    # environment's, and it is made as itself or not at all.
    _ = File.mkdir_p(Path.dirname(dir))
    _ = File.mkdir(dir)

    case kind(dir) do
      :directory -> File.chmod(dir, 0o700)
      other -> {:error, {:not_a_directory, other}}
    end
  end

  # Only a socket an earlier listener left is removed.
  defp clear(path) do
    case kind(path) do
      :none -> :ok
      :socket -> File.rm(path)
      other -> {:error, {:not_a_socket, other}}
    end
  end

  defp private(socket, path) do
    with {:error, _} = error <- File.chmod(path, 0o600) do
      :gen_tcp.close(socket)
      error
    end
  end

  defp listen_opts(path) do
    [
      :binary,
      {:ifaddr, {:local, path}},
      active: false,
      backlog: 16,
      packet: :http_bin,
      packet_size: @max_line,
      send_timeout: 10_000,
      send_timeout_close: true
    ]
  end

  # Ends when its socket is closed (the listener was replaced, or the
  # server stopped) or fails for good; the server hears of it and the
  # next ensure listens again. Running out of descriptors passes.
  defp accept(listen, api) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        hand_over(socket, api)
        accept(listen, api)

      {:error, reason} when reason in [:emfile, :enfile, :enomem, :enobufs, :econnaborted] ->
        Process.sleep(200)
        accept(listen, api)

      {:error, _} ->
        :ok
    end
  end

  # A client past the limit is hung up on here, with no process of its
  # own and nothing read from it.
  defp hand_over(socket, api) do
    with {:ok, pid} <- reserve(api),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      send(pid, {:serve, socket})
    else
      _ -> :gen_tcp.close(socket)
    end
  end

  defp reserve(api) do
    GenServer.call(api, :reserve)
  catch
    :exit, _ -> :full
  end

  # Waits for the socket it was made for. One that never comes (the
  # acceptor died between the two) frees its place.
  defp client(ctx) do
    receive do
      {:serve, socket} ->
        serve(socket, ctx)
        :gen_tcp.close(socket)
    after
      5_000 -> :ok
    end
  end

  defp serve(socket, ctx) do
    deadline = System.monotonic_time(:millisecond) + ctx.read_timeout

    reply =
      with {:ok, method, target} <- request_line(socket, deadline),
           {:ok, headers} <- headers(socket, deadline, %{}, 0),
           {:ok, length} <- content_length(headers),
           :ok <- continue(socket, headers, length),
           {:ok, body} <- body(socket, length, deadline) do
        ask(ctx.relay, request(method, target, body, headers))
      end

    if reply != :closed, do: respond(socket, reply)
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp request_line(socket, deadline) do
    case :gen_tcp.recv(socket, 0, left(deadline)) do
      {:ok, {:http_request, method, {:abs_path, target}, {1, _minor}}}
      when byte_size(target) <= @max_target ->
        # As written: the box decides which methods it relays.
        method = to_string(method)
        if token?(method) and plain?(target), do: {:ok, method, target}, else: malformed()

      result ->
        unread(result)
    end
  end

  defp headers(_socket, _deadline, _seen, count) when count > @max_headers, do: malformed()

  defp headers(socket, deadline, seen, count) do
    case :gen_tcp.recv(socket, 0, left(deadline)) do
      {:ok, {:http_header, _, name, _, value}} ->
        name = name |> to_string() |> String.downcase()

        cond do
          name not in ~w(content-length transfer-encoding expect idempotency-key) ->
            headers(socket, deadline, seen, count + 1)

          # Two of one of these have no one meaning.
          Map.has_key?(seen, name) ->
            malformed()

          name == "idempotency-key" and not plain?(value) ->
            malformed()

          true ->
            headers(socket, deadline, Map.put(seen, name, value), count + 1)
        end

      {:ok, :http_eoh} ->
        {:ok, seen}

      result ->
        unread(result)
    end
  end

  # What goes to the box goes as text in a frame, and the box passes
  # nothing but plain ASCII in a target or a key. Anything else is
  # refused here, where it costs one client its request and nobody a
  # connection.
  defp plain?(text), do: Regex.match?(~r/\A[\x21-\x7E]+\z/, text)
  defp token?(method), do: Regex.match?(~r/\A[A-Za-z]{1,16}\z/, method)

  defp unread({:error, :closed}), do: :closed

  defp unread({:error, :timeout}),
    do: error(408, "request_timeout", "The request took too long to arrive.")

  defp unread(_other), do: malformed()

  defp malformed, do: error(400, "invalid_request", "The request could not be parsed.")

  defp content_length(%{"transfer-encoding" => _}),
    do: error(411, "length_required", "Send the request body with a Content-Length.")

  defp content_length(%{"content-length" => value}) do
    if Regex.match?(~r/\A[0-9]{1,9}\z/, value) do
      case String.to_integer(value) do
        length when length <= @max_body -> {:ok, length}
        _ -> error(413, "request_too_large", "The request body exceeds the size limit.")
      end
    else
      malformed()
    end
  end

  defp content_length(_headers), do: {:ok, 0}

  defp continue(socket, %{"expect" => expect}, length) when length > 0 do
    if String.downcase(expect) == "100-continue",
      do: :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")

    :ok
  end

  defp continue(_socket, _headers, _length), do: :ok

  defp body(_socket, 0, _deadline), do: {:ok, ""}

  defp body(socket, length, deadline) do
    with :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, body} <- :gen_tcp.recv(socket, length, left(deadline)) do
      # It travels to the box as text.
      if String.valid?(body), do: {:ok, body}, else: malformed()
    else
      result -> unread(result)
    end
  end

  defp request(method, target, body, headers) do
    %{"method" => method, "target" => target}
    |> put_present("body", if(body != "", do: body))
    |> put_present("idempotency_key", headers["idempotency-key"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp ask(relay, request) do
    case relay.(request) do
      {:ok, %{status: status, body: body, headers: headers}}
      when is_integer(status) and is_binary(body) and is_map(headers) ->
        %{status: status, body: body, headers: headers}

      {:error, :not_connected} ->
        error(503, "relay_unavailable", "The box isn't connected to this environment yet.")

      {:error, :busy} ->
        error(429, "relay_busy", "Too many requests at once. Try again shortly.")

      {:error, :timeout} ->
        error(504, "relay_timeout", "The box took too long to answer.")

      {:error, :too_large} ->
        error(413, "request_too_large", "The request is too large to send to the box.")

      _ ->
        failed()
    end
  rescue
    e ->
      Logger.warning("a public API request failed: #{Exception.message(e)}")
      failed()
  catch
    :exit, _ -> failed()
  end

  defp failed, do: error(502, "relay_failed", "The request couldn't be sent to the box.")

  defp error(status, code, message),
    do: %{status: status, body: JSON.encode!(%{code: code, message: message}), headers: %{}}

  defp respond(socket, %{status: status, body: body, headers: headers}) do
    extra =
      for name <- @passed_back,
          value = headers[name],
          is_binary(value) and not String.contains?(value, ["\r", "\n"]),
          do: [name, ": ", value, "\r\n"]

    reason = Map.get(@reasons, status, "Status")

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      extra,
      "\r\n",
      body
    ])

    :gen_tcp.shutdown(socket, :write)
    # Closing with the client's bytes unread resets the connection, and
    # the client loses the answer with it. Read what it's still sending,
    # for a moment in all, however it sends it.
    _ = :inet.setopts(socket, packet: :raw)
    drain(socket, System.monotonic_time(:millisecond) + @linger)
  end

  defp drain(socket, deadline) do
    case left(deadline) do
      0 ->
        :ok

      wait ->
        case :gen_tcp.recv(socket, 0, wait) do
          {:ok, _data} -> drain(socket, deadline)
          {:error, _} -> :ok
        end
    end
  end
end
