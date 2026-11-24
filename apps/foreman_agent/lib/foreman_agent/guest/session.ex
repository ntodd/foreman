defmodule ForemanAgent.Guest.Session do
  @moduledoc """
  One host connection to the guest agent (see `ForemanAgent.Channel`).

  Commands go to `ForemanAgent.Ops` as they would from the control plane,
  so a command the host sends again after a reconnect (same op id) gets
  the result the guest already has, or waits for the one still running.
  Their events come back through `ForemanAgent.Outbox`, which this session
  attaches to once the host says hello: results the host hasn't
  acknowledged are delivered again on every connection. An Outbox that
  restarts has no session attached, so the session closes the connection
  when it goes: the host reconnects, and its hello attaches the new one.
  The session's hello carries the Ops server's instance id, so the host
  can tell when a restart has made it forget what it ran.

  The host drops the connection on a frame past
  `ForemanAgent.Channel.max_frame(:to_host)`, and a result is delivered
  again on every connection until it's acknowledged, so a result too
  large to send goes as an error instead.

  Options (all have defaults that use the application's processes):

    * `:ops`, `:outbox` - the servers commands and events go through (a
      pid or a locally registered name)
    * `:queries` - `%{"inventory" => fun, "ports" => fun, "reclaim" => fun}`,
      each returning `{:ok, term}` or `{:error, message}`. A function of one
      argument gets the query's `args` (an empty map when there are none).
    * `:clock` - `fn host_now_ms -> any end`, called with the host's time
    * `:configure` - `fn config_map -> any end`, called with the host's config
  """
  use GenServer

  alias ForemanAgent.{Channel, Ops, Outbox}
  alias ForemanProtocol.{Command, Event}

  require Logger

  @request_fields ~w(method target body idempotency_key)

  # A little longer than the box gives the control plane to answer.
  @request_timeout 40_000
  # Public API requests waiting on the box at once. The box relays fewer
  # at a time, and answers the rest that it's busy.
  @max_requests 32
  # And the bytes they may hold between them. The box reads this
  # connection at a steady rate, and everything on it waits its turn
  # behind what was sent first, a command's result included: this is how
  # far ahead of one the environment's own requests can get.
  @max_request_bytes 2 * 1_048_576

  @doc "Starts a session for an accepted socket; it reads once `go/1` hands it over."
  def start(socket, opts), do: GenServer.start(__MODULE__, {socket, opts})

  def go(pid), do: send(pid, :go)

  # One that has already ended is closed. The box reconnects the moment its
  # old connection is gone, which can be before whoever holds this session
  # has heard that it stopped.
  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Asks the box, through `session` and within its `budget/0`, to relay a
  public API request (`ForemanAgent.Guest.API` builds it): `"method"`, `"target"` and, where there are any, `"body"`
  and `"idempotency_key"`. The box decides whether it may be sent and for
  which environment (`ForemanAgent.VM.Relay`).

  `{:error, reason}` when there's no answer to give: `:not_connected`
  (the box hasn't said hello on this connection, or it dropped), `:busy`
  (too many waiting, or too much), `:too_large`, `:timeout`, or
  `:invalid` for a request that isn't text all through.
  """
  @spec request({pid(), :atomics.atomics_ref()}, map(), timeout()) ::
          {:ok, map()} | {:error, atom()}
  def request({session, budget}, request, timeout \\ @request_timeout) when is_map(request) do
    # Checked, sized and counted here, in the caller: the session may be
    # held up writing to a box that isn't reading, and what waits for it
    # then must already be within what the connection allows.
    with {:ok, frame, size} <- api_frame(request),
         :ok <- reserve(budget, size) do
      ref = Process.monitor(session)
      deadline = if is_integer(timeout), do: System.monotonic_time(:millisecond) + timeout
      send(session, {:api, self(), ref, frame, size, deadline})

      receive do
        {:api_reply, ^ref, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, _pid, _reason} ->
          {:error, :not_connected}
      after
        timeout ->
          Process.demonitor(ref, [:flush])
          send(session, {:api_gone, ref})
          {:error, :timeout}
      end
    else
      :error -> {:error, :invalid}
      {:error, :busy} -> {:error, :busy}
    end
  end

  @doc """
  What a connection's requests may hold between them: a count and a number
  of bytes, kept where a caller can reserve from them without asking the
  session. `ForemanAgent.Guest.Server` makes one for each connection.
  """
  def budget, do: :atomics.new(2, signed: true)

  defp reserve(budget, size) do
    count = :atomics.add_get(budget, 1, 1)
    bytes = :atomics.add_get(budget, 2, size)

    if count > @max_requests or bytes > @max_request_bytes do
      release(budget, size)
      {:error, :busy}
    else
      :ok
    end
  end

  # Only the session gives back what a caller reserved: when the box has
  # answered, or when the request was never sent. A caller that stops
  # waiting says nothing about whether the box has read its frame yet.
  defp release(budget, size) do
    :atomics.sub(budget, 1, 1)
    :atomics.sub(budget, 2, size)
  end

  # The frame for a request, and the bytes it counts for. Every field is
  # text or left out: what isn't can't be put in a frame, and trying
  # would take the session down with the commands it carries.
  defp api_frame(request) do
    fields = Map.take(request, @request_fields)

    with %{"method" => _, "target" => _} <- fields,
         true <-
           Enum.all?(fields, fn {_name, value} -> is_binary(value) and String.valid?(value) end) do
      frame = Map.put(fields, "t", "api")
      # What it will take on the wire, escapes and all, with room for its id.
      {:ok, frame, IO.iodata_length(Channel.encode(frame)) + 32}
    else
      _ -> :error
    end
  end

  @impl true
  def init({socket, opts}) do
    {:ok,
     %{
       socket: socket,
       ops: Keyword.get(opts, :ops, Ops),
       outbox: Keyword.get(opts, :outbox, Outbox),
       queries: Keyword.get_lazy(opts, :queries, &ForemanAgent.Guest.queries/0),
       clock: Keyword.get(opts, :clock, &ForemanAgent.Guest.sync_clock/1),
       configure: Keyword.get(opts, :configure, &ForemanAgent.Guest.configure/1),
       # The monitors on the Outbox this session attached to, and on Ops.
       attached: nil,
       ops_watch: nil,
       # Public API requests the box hasn't answered: id => {pid, ref, bytes},
       # and what callers have reserved for them and for those still on
       # their way here.
       requests: %{},
       budget: Keyword.get_lazy(opts, :budget, &budget/0),
       next_request: 1
     }}
  end

  @impl true
  def handle_info(:go, state) do
    :ok = :inet.setopts(state.socket, Channel.frame_opts(:guest) ++ [active: :once])
    {:noreply, state}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state =
      case Channel.decode(data) do
        {:ok, frame} ->
          handle_frame(frame, state)

        {:error, :malformed} ->
          Logger.warning("ignoring a malformed frame from the host")
          state
      end

    :ok = :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  # Its supervisor logs why it stopped.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{attached: ref} = state) do
    Logger.info("the outbox stopped; closing the host connection so it attaches again")
    {:stop, :normal, state}
  end

  # A new Ops knows nothing of what the old one ran; the host hears of it
  # (a new instance) at the next hello, and fails what it had sent.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ops_watch: ref} = state) do
    Logger.info("operations stopped; closing the host connection so it hears of the new ones")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("the host connection failed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:outbox_deliver, %Event{} = event, seq}, state) do
    with {:error, :too_large} <- send_event(state, event, seq) do
      Logger.warning("an #{event.type} event is too large to send to the host")
      with {:ok, smaller} <- too_large(event), do: send_event(state, smaller, seq)
    end

    {:noreply, state}
  end

  def handle_info({:reply, id, result}, state) do
    frame =
      case result do
        {:ok, value} -> %{"t" => "reply", "id" => id, "ok" => true, "result" => value}
        {:error, message} -> %{"t" => "reply", "id" => id, "ok" => false, "error" => message}
      end

    send_frame(state, frame)
    {:noreply, state}
  end

  # A public API request for the box, already checked and counted by its
  # caller (`request/3`). Not sent when the box hasn't said hello (it
  # would drop the frame, and the client would wait for nothing), or when
  # it waited here past its caller's patience: nobody is left to take the
  # answer, and the caller may have asked again.
  def handle_info({:api, pid, ref, frame, size, deadline}, state) do
    with :ok <- wanted(pid, deadline),
         :ok <- attached(state),
         id = state.next_request,
         :ok <- send_frame(state, Map.put(frame, "id", id)) do
      requests = Map.put(state.requests, id, {pid, ref, size})
      {:noreply, %{state | requests: requests, next_request: id + 1}}
    else
      {:error, reason} ->
        release(state.budget, size)
        known? = reason in [:not_connected, :too_large, :timeout]
        send(pid, {:api_reply, ref, {:error, if(known?, do: reason, else: :not_connected)}})
        {:noreply, state}
    end
  end

  # A client that stopped waiting. The box's answer, if it comes, is
  # dropped, and the request stays counted until then: the box may not
  # have read its frame yet.
  def handle_info({:api_gone, ref}, state) do
    requests =
      Map.new(state.requests, fn
        {id, {_pid, ^ref, size}} -> {id, {nil, ref, size}}
        other -> other
      end)

    {:noreply, %{state | requests: requests}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
  end

  defp handle_frame(%{"t" => "hello"} = frame, state) do
    sync_clock(frame, state)
    if is_map(frame["config"]), do: state.configure.(frame["config"])

    send_frame(state, %{
      "t" => "hello",
      "agent_version" => ForemanAgent.Identity.version(),
      "instance" => Ops.instance(state.ops)
    })

    attach(state)
  end

  defp handle_frame(%{"t" => "cmd", "cmd" => wire} = frame, state) do
    sync_clock(frame, state)

    case Command.from_wire(wire) do
      {:ok, cmd} -> Ops.submit(state.ops, cmd)
      {:error, errors} -> reject(wire, errors, state)
    end

    state
  end

  defp handle_frame(%{"t" => "cancel", "op_id" => op_id}, state) when is_binary(op_id) do
    case Command.new("op.cancel", %{target_op_id: op_id}) do
      {:ok, cmd} -> Ops.submit(state.ops, cmd)
      {:error, _} -> :ok
    end

    state
  end

  defp handle_frame(%{"t" => "ack", "seq" => seq}, state) when is_integer(seq) do
    Outbox.ack(state.outbox, seq)
    state
  end

  defp handle_frame(%{"t" => "query", "id" => id, "q" => q} = frame, state) when is_integer(id) do
    session = self()
    args = if is_map(frame["args"]), do: frame["args"], else: %{}

    case Map.fetch(state.queries, q) do
      {:ok, fun} ->
        Task.start(fn -> send(session, {:reply, id, run_query(fun, args)}) end)

      :error ->
        send(session, {:reply, id, {:error, "unknown query"}})
    end

    state
  end

  defp handle_frame(%{"t" => "api.reply", "id" => id} = frame, state) when is_integer(id) do
    case settle(state, id) do
      {{pid, ref}, state} ->
        if pid, do: send(pid, {:api_reply, ref, api_reply(frame)})
        state

      {nil, state} ->
        state
    end
  end

  defp handle_frame(%{"t" => type}, state) do
    Logger.warning("ignoring a #{inspect(type)} frame from the host")
    state
  end

  defp wanted(pid, deadline) do
    if Process.alive?(pid) and
         (is_nil(deadline) or System.monotonic_time(:millisecond) < deadline),
       do: :ok,
       else: {:error, :timeout}
  end

  defp attached(%{attached: nil}), do: {:error, :not_connected}
  defp attached(_state), do: :ok

  # Takes an answered request off the list and gives back what it held.
  # The waiter is nil when its caller stopped waiting.
  defp settle(state, id) do
    case Map.pop(state.requests, id) do
      {{pid, ref, size}, requests} ->
        release(state.budget, size)
        {{pid, ref}, %{state | requests: requests}}

      {nil, _} ->
        {nil, state}
    end
  end

  defp api_reply(%{"status" => status, "body" => body} = frame)
       when is_integer(status) and status in 100..599 and is_binary(body) do
    headers = if is_map(frame["headers"]), do: frame["headers"], else: %{}
    {:ok, %{status: status, body: body, headers: Map.filter(headers, &header?/1)}}
  end

  defp api_reply(_frame), do: {:error, :invalid}

  defp header?({name, value}), do: is_binary(name) and is_binary(value)

  # Monitored before it attaches, so an Outbox that restarts from here on
  # closes the session (see the moduledoc).
  defp attach(state) do
    if state.attached, do: Process.demonitor(state.attached, [:flush])
    if state.ops_watch, do: Process.demonitor(state.ops_watch, [:flush])
    attached = Process.monitor(state.outbox)
    ops_watch = Process.monitor(state.ops)
    :ok = Outbox.attach(state.outbox, self())
    %{state | attached: attached, ops_watch: ops_watch}
  end

  defp run_query(fun, args) do
    if is_function(fun, 1), do: fun.(args), else: fun.()
  rescue
    e -> {:error, "query failed: #{Exception.message(e)}"}
  end

  defp sync_clock(%{"now" => now}, state) when is_integer(now), do: state.clock.(now)
  defp sync_clock(_frame, _state), do: :ok

  # A command that fails validation still gets a result, if it has an op
  # id the host can match it to.
  defp reject(%{"op_id" => op_id}, errors, state) when is_binary(op_id) do
    case Event.new("op.result", %{
           op_id: op_id,
           status: "error",
           error: "invalid command: #{inspect(errors)}"
         }) do
      {:ok, event} -> Outbox.push(state.outbox, event)
      {:error, _} -> :ok
    end
  end

  defp reject(_wire, _errors, _state), do: :ok

  defp send_event(state, event, seq),
    do: send_frame(state, %{"t" => "event", "seq" => seq, "event" => Event.to_wire(event)})

  # Ops only sends op events; a log chunk too large is dropped.
  defp too_large(%Event{type: "op.result", payload: %{op_id: op_id}}) do
    Event.new("op.result", %{
      op_id: op_id,
      status: "error",
      error: "the result was too large to send to the box"
    })
  end

  defp too_large(_event), do: :drop

  defp send_frame(state, frame) do
    case Channel.send_frame(state.socket, frame, Channel.max_frame(:to_host)) do
      :ok ->
        :ok

      {:error, :too_large} = error ->
        error

      {:error, reason} = error ->
        Logger.warning("couldn't send to the host: #{inspect(reason)}")
        error
    end
  end
end
