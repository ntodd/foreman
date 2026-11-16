defmodule ForemanAgent.VM.Link do
  @moduledoc """
  The host's end of `ForemanAgent.Channel`: one per running environment
  VM, connected to the agent in it.

  `run/4` sends a command and waits for its result, passing its logs to
  the caller's log function as they come. When the connection drops, the
  link reconnects and sends every command still waiting again, with the
  same op id: the guest runs each one once (see `ForemanAgent.Ops`) and
  answers with the result it has. A caller that goes away (an operation
  cancelled on the box) has its command cancelled in the guest too.

  Everything the guest sends is hostile. Frames past
  `ForemanAgent.Channel.max_frame/0` close the connection; anything that
  isn't a valid event, reply or hello is dropped; and an event only
  reaches the caller whose command it names. Results for commands nobody
  is waiting for (one that finished while the box's agent restarted) are
  kept, a few, until the command is sent again.

  Options:

    * `:socket` - the VM's hybrid vsock socket (required)
    * `:config` - what the guest is told in `hello` (see `ForemanAgent.Channel`)
    * `:alive?` - `fn -> boolean end`: whether the VM is still running. Once
      it isn't, everything waiting fails and the link stops.
    * `:retry` - milliseconds between connection attempts (default 250)
  """
  use GenServer

  alias ForemanAgent.Channel
  alias ForemanProtocol.{Command, Event}

  require Logger

  @op_events ["op.accepted", "op.log", "op.result"]
  @kept_results 100
  @connect_timeout 2_000

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Runs a command in the guest and returns its result. `log` gets each
  chunk of output as `log.(stream, data)`, in this process.
  """
  @spec run(GenServer.server(), Command.t(), (String.t(), String.t() -> any())) ::
          {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def run(link, %Command{} = cmd, log) do
    ref = make_ref()
    monitor = Process.monitor(link)

    try do
      :ok = GenServer.call(link, {:run, cmd, self(), ref})
      await(ref, monitor, log)
    catch
      :exit, _ -> {:error, "lost the connection to the environment's VM"}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await(ref, monitor, log) do
    receive do
      {:link_log, ^ref, stream, data} ->
        log.(stream, data)
        await(ref, monitor, log)

      {:link_result, ^ref, result} ->
        result

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, "lost the connection to the environment's VM"}
    end
  end

  @doc "Asks the guest a query (`inventory`, `ports`)."
  @spec query(GenServer.server(), String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def query(link, q, timeout \\ 5_000) do
    GenServer.call(link, {:query, q, timeout}, timeout + 1_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc "Whether the link is connected to the guest agent."
  def connected?(link), do: GenServer.call(link, :connected?)

  @impl true
  def init(opts) do
    send(self(), :connect)

    {:ok,
     %{
       path: Keyword.fetch!(opts, :socket),
       config: Keyword.get(opts, :config, %{}),
       alive?: Keyword.get(opts, :alive?, fn -> true end),
       retry: Keyword.get(opts, :retry, 250),
       socket: nil,
       guest_version: nil,
       # op_id => %{cmd, caller, ref, monitor}
       pending: %{},
       # query id => {from, timer}
       queries: %{},
       next_query: 1,
       # op_id => result, for commands nobody was waiting for
       kept: %{},
       kept_order: :queue.new()
     }}
  end

  @impl true
  def handle_call({:run, %Command{op_id: op_id} = cmd, caller, ref}, _from, state) do
    case Map.pop(state.kept, op_id) do
      {nil, _} ->
        state = drop_pending(state, op_id)
        monitor = Process.monitor(caller)
        entry = %{cmd: cmd, caller: caller, ref: ref, monitor: monitor}
        state = put_in(state.pending[op_id], entry)
        send_cmd(state, cmd)
        {:reply, :ok, state}

      {result, kept} ->
        send(caller, {:link_result, ref, result})
        {:reply, :ok, %{state | kept: kept}}
    end
  end

  def handle_call({:query, _q, _timeout}, _from, %{socket: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:query, q, timeout}, from, state) do
    id = state.next_query
    timer = Process.send_after(self(), {:query_timeout, id}, timeout)
    send_frame(state, %{"t" => "query", "id" => id, "q" => q})
    {:noreply, %{state | next_query: id + 1, queries: Map.put(state.queries, id, {from, timer})}}
  end

  def handle_call(:connected?, _from, state), do: {:reply, state.socket != nil, state}

  @impl true
  def handle_info(:connect, %{socket: nil} = state) do
    case connect(state) do
      {:ok, socket} ->
        state = %{state | socket: socket}
        Enum.each(state.pending, fn {_, entry} -> send_cmd(state, entry.cmd) end)
        {:noreply, state}

      {:error, reason} ->
        if state.alive?.() do
          Process.send_after(self(), :connect, state.retry)
          {:noreply, state}
        else
          Logger.info("the VM at #{state.path} isn't running (#{inspect(reason)})")
          {:stop, :normal, fail_all(state, "the environment's VM isn't running")}
        end
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state =
      case Channel.decode(data) do
        {:ok, frame} -> handle_frame(frame, state)
        {:error, :malformed} -> state
      end

    :ok = :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: disconnected(state)

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("the connection to the VM at #{state.path} failed: #{inspect(reason)}")
    :gen_tcp.close(socket)
    disconnected(state)
  end

  def handle_info({:query_timeout, id}, state) do
    case Map.pop(state.queries, id) do
      {{from, _timer}, queries} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | queries: queries}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # A caller that went away (its operation cancelled) takes its command
  # with it.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.pending, fn {_, e} -> e.monitor == monitor end) do
      {op_id, _} ->
        send_frame(state, %{"t" => "cancel", "op_id" => op_id})
        {:noreply, %{state | pending: Map.delete(state.pending, op_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp connect(state) do
    opts = [:binary, packet: :line, active: false]

    with {:ok, socket} <- :gen_tcp.connect({:local, state.path}, 0, opts, @connect_timeout),
         :ok <- handshake(socket),
         :ok <- :inet.setopts(socket, Channel.frame_opts()),
         :ok <- Channel.send_frame(socket, hello(state)),
         :ok <- :inet.setopts(socket, active: :once) do
      {:ok, socket}
    end
  end

  # Cloud Hypervisor's side of the socket: it answers OK once the guest
  # has accepted the connection on the port.
  defp handshake(socket) do
    with :ok <- :gen_tcp.send(socket, "CONNECT #{Channel.port()}\n") do
      case :gen_tcp.recv(socket, 0, @connect_timeout) do
        {:ok, "OK" <> _} ->
          :ok

        other ->
          :gen_tcp.close(socket)
          {:error, {:handshake, other}}
      end
    end
  end

  defp hello(state), do: %{"t" => "hello", "now" => Channel.now(), "config" => state.config}

  defp disconnected(state) do
    send(self(), :connect)

    state.queries
    |> Enum.each(fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :disconnected})
    end)

    {:noreply, %{state | socket: nil, queries: %{}}}
  end

  defp handle_frame(%{"t" => "event", "event" => wire} = frame, state) do
    case Event.from_wire(wire) do
      {:ok, %Event{type: type} = event} when type in @op_events ->
        ack(state, frame["seq"])
        dispatch(event, state)

      _ ->
        ack(state, frame["seq"])
        state
    end
  end

  defp handle_frame(%{"t" => "reply", "id" => id} = frame, state) when is_integer(id) do
    case Map.pop(state.queries, id) do
      {{from, timer}, queries} ->
        Process.cancel_timer(timer)

        reply =
          if frame["ok"] == true,
            do: {:ok, frame["result"]},
            else: {:error, to_string_safe(frame["error"])}

        GenServer.reply(from, reply)
        %{state | queries: queries}

      {nil, _} ->
        state
    end
  end

  defp handle_frame(%{"t" => "hello", "agent_version" => version}, state) when is_binary(version),
    do: %{state | guest_version: String.slice(version, 0, 64)}

  defp handle_frame(_frame, state), do: state

  defp dispatch(%Event{type: "op.accepted"}, state), do: state

  defp dispatch(%Event{type: "op.log", payload: p}, state) do
    case state.pending[p.op_id] do
      %{caller: caller, ref: ref} -> send(caller, {:link_log, ref, p.stream, p.data})
      nil -> :ok
    end

    state
  end

  defp dispatch(%Event{type: "op.result", payload: p}, state) do
    result = result(p)

    case Map.pop(state.pending, p.op_id) do
      {%{caller: caller, ref: ref, monitor: monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        send(caller, {:link_result, ref, result})
        %{state | pending: pending}

      {nil, _} ->
        keep(state, p.op_id, result)
    end
  end

  defp result(%{status: "ok"} = p), do: {:ok, Map.get(p, :result, %{})}

  defp result(%{status: "error"} = p) do
    message = Map.get(p, :error) || "failed"

    case Map.get(p, :result, %{}) do
      empty when empty == %{} -> {:error, message}
      map -> {:error, message, map}
    end
  end

  defp keep(state, op_id, result) do
    order = :queue.in(op_id, state.kept_order)
    kept = Map.put(state.kept, op_id, result)

    if :queue.len(order) > @kept_results do
      {{:value, oldest}, order} = :queue.out(order)
      %{state | kept: Map.delete(kept, oldest), kept_order: order}
    else
      %{state | kept: kept, kept_order: order}
    end
  end

  defp ack(state, seq) when is_integer(seq), do: send_frame(state, %{"t" => "ack", "seq" => seq})
  defp ack(_state, _seq), do: :ok

  defp send_cmd(state, cmd) do
    send_frame(state, %{"t" => "cmd", "now" => Channel.now(), "cmd" => Command.to_wire(cmd)})
  end

  defp send_frame(%{socket: nil}, _frame), do: :ok

  defp send_frame(%{socket: socket}, frame) do
    case Channel.send_frame(socket, frame) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("couldn't send to the VM: #{inspect(reason)}")
    end
  end

  defp drop_pending(state, op_id) do
    case Map.pop(state.pending, op_id) do
      {%{caller: caller, ref: ref, monitor: monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        send(caller, {:link_result, ref, {:error, "sent again"}})
        %{state | pending: pending}

      {nil, _} ->
        state
    end
  end

  defp fail_all(state, message) do
    Enum.each(state.pending, fn {_, e} ->
      send(e.caller, {:link_result, e.ref, {:error, message}})
    end)

    Enum.each(state.queries, fn {_, {from, _}} ->
      GenServer.reply(from, {:error, :not_running})
    end)

    %{state | pending: %{}, queries: %{}}
  end

  defp to_string_safe(value) when is_binary(value), do: String.slice(value, 0, 1_000)
  defp to_string_safe(_), do: "failed"
end
