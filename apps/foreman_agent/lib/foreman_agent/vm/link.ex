defmodule ForemanAgent.VM.Link do
  @moduledoc """
  The host's end of `ForemanAgent.Channel`: one per running environment
  VM, connected to the agent in it.

  The link counts as connected once the guest agent has answered its
  hello: Cloud Hypervisor accepts the vsock connection as soon as `socat`
  is listening in the guest, which can be before the agent is.

  `run/4` sends a command and waits for its result, passing its logs to
  the caller's log function as they come. When the connection drops, the
  link reconnects and sends every command still waiting again, with the
  same op id: the guest runs each one once (see `ForemanAgent.Ops`) and
  answers with the result it has. That holds while it's the same guest
  agent. Each hello carries the agent's instance id, and when that
  changes (the agent or the VM restarted, and forgot what it ran), the
  commands it was sent fail rather than run again. A caller that goes
  away (an operation cancelled on the box), or runs out of time, has its
  command cancelled in the guest too: straight away, or after the next
  hello when the connection is down.

  Everything the guest sends is hostile:

    * Frames past `ForemanAgent.Channel.max_frame(:to_host)` close the
      connection, and decoding one has a limit on memory and time.
    * Anything that isn't a valid event, reply or hello is dropped, and
      so is a hello after the first on a connection.
    * An event only reaches the caller whose command it names. A result
      nobody is waiting for is dropped: if the command is sent again, the
      guest has it.
    * A command's log is passed on up to `:log_budget` bytes. The link
      reads nothing more from the guest while a caller has more than
      `@log_window` bytes of log it hasn't taken yet.
    * Sends time out, so a guest that stops reading can't hold the link
      up. Reconnects back off, and connection warnings are rate-limited.
    * Query replies are checked for size and type, and text from the
      guest loses its control characters.

  Options:

    * `:socket` - the VM's hybrid vsock socket (required)
    * `:config` - what the guest is told in `hello` (see `ForemanAgent.Channel`)
    * `:alive?` - `fn -> boolean end`: whether the VM is still running. Once
      it isn't, everything waiting fails and the link stops.
    * `:retry` - milliseconds before the first reconnect (default 250).
      The wait doubles with each failure, up to `:max_retry` (default
      10 seconds), and starts again once a connection has stayed up
      that long.
    * `:send_timeout` - milliseconds a send to the guest may take before
      the link gives up on the connection (default 5 seconds)
    * `:log_budget` - bytes of log passed on per command (default 64 MiB)
  """
  use GenServer

  alias ForemanAgent.{Channel, Text}
  alias ForemanProtocol.{Command, Event}

  require Logger

  @op_events ["op.accepted", "op.log", "op.result"]
  @connect_timeout 2_000
  # How long the guest agent gets to answer hello on a new connection.
  @hello_timeout 5_000
  # Log bytes a caller hasn't taken yet: past this, the guest waits.
  @log_window 1_048_576
  @log_dropped "the VM sent more log than the box keeps; the rest is dropped\n"
  # The largest query result passed on (its external term size).
  @max_reply 262_144
  # At most one connection warning this often (milliseconds).
  @warn_every 60_000

  @lost "lost the connection to the environment's VM"
  @restarted "the environment's VM restarted while running it"
  @timed_out "the environment's VM didn't finish it in time"
  @too_large "the command is too large to send to the environment's VM"
  @invalid_reply "the environment's VM sent an invalid reply"

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Runs a command in the guest and returns its result. `log` gets each
  chunk of output as `log.(stream, data)`, in this process.

  Options:

    * `:timeout` - milliseconds to wait for the result (default
      `:infinity`). A command that takes longer is cancelled in the
      guest.
  """
  @spec run(GenServer.server(), Command.t(), (String.t(), String.t() -> any()), keyword()) ::
          {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def run(link, %Command{} = cmd, log, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    # Checked here: a bad one would take the link down with it.
    unless timeout == :infinity or (is_integer(timeout) and timeout >= 0),
      do:
        raise(
          ArgumentError,
          "timeout must be :infinity or milliseconds, got: #{inspect(timeout)}"
        )

    ref = make_ref()
    monitor = Process.monitor(link)

    try do
      :ok = GenServer.call(link, {:run, cmd, self(), ref, timeout})
      await(link, cmd.op_id, ref, monitor, log)
    catch
      :exit, _ -> {:error, @lost}
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  # Each chunk of log taken lets the link read on (see @log_window).
  defp await(link, op_id, ref, monitor, log) do
    receive do
      {:link_log, ^ref, stream, data} ->
        log.(stream, data)
        GenServer.cast(link, {:log_taken, op_id, ref, byte_size(data)})
        await(link, op_id, ref, monitor, log)

      {:link_result, ^ref, result} ->
        result

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, @lost}
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
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(link) do
    GenServer.call(link, :connected?)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(opts) do
    send(self(), :connect)
    retry = Keyword.get(opts, :retry, 250)

    {:ok,
     %{
       path: Keyword.fetch!(opts, :socket),
       config: Keyword.get(opts, :config, %{}),
       alive?: Keyword.get(opts, :alive?, fn -> true end),
       retry: retry,
       max_retry: Keyword.get(opts, :max_retry, 10_000),
       send_timeout: Keyword.get(opts, :send_timeout, 5_000),
       log_budget: Keyword.get(opts, :log_budget, 64 * 1_048_576),
       # The wait before the next connection attempt.
       backoff: retry,
       socket: nil,
       # Whether the socket will pass on the guest's next frame.
       armed: false,
       # Whether the guest agent has answered this connection's hello, and when.
       ready: false,
       ready_at: nil,
       # The guest agent instance of the last hello.
       instance: nil,
       guest_version: nil,
       # op_id => %{cmd, caller, ref, monitor, timer, sent_to, logged, over, untaken}
       pending: %{},
       # Op ids to cancel once the guest says hello.
       cancels: MapSet.new(),
       # query id => {from, q, timer}
       queries: %{},
       next_query: 1,
       warned_at: nil,
       unwarned: 0
     }}
  end

  @impl true
  def handle_call({:run, %Command{op_id: op_id} = cmd, caller, ref, timeout}, _from, state) do
    state = finish(state, op_id, {:error, "sent again"})

    timer =
      if timeout != :infinity,
        do: Process.send_after(self(), {:run_timeout, op_id, ref}, timeout)

    entry = %{
      cmd: cmd,
      caller: caller,
      ref: ref,
      monitor: Process.monitor(caller),
      timer: timer,
      # The guest agent instance it was sent to.
      sent_to: nil,
      # Log bytes passed on, whether it's past the budget, and how much of
      # it the caller hasn't taken yet.
      logged: 0,
      over: false,
      untaken: 0
    }

    state = %{
      state
      | pending: Map.put(state.pending, op_id, entry),
        cancels: MapSet.delete(state.cancels, op_id)
    }

    # Not ready yet: it goes with the rest once the guest says hello.
    state = if state.ready, do: send_cmd(state, op_id), else: state
    {:reply, :ok, state}
  end

  def handle_call({:query, _q, _timeout}, _from, %{ready: false} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:query, q, timeout}, from, state) do
    id = state.next_query
    timer = Process.send_after(self(), {:query_timeout, id}, timeout)
    # One that fails is answered when the connection closes.
    {_, state} = send_frame(state, %{"t" => "query", "id" => id, "q" => q})

    {:noreply,
     %{state | next_query: id + 1, queries: Map.put(state.queries, id, {from, q, timer})}}
  end

  def handle_call(:connected?, _from, state), do: {:reply, state.ready, state}

  @impl true
  def handle_cast({:log_taken, op_id, ref, bytes}, state) do
    state =
      case state.pending do
        %{^op_id => %{ref: ^ref} = entry} ->
          entry = %{entry | untaken: max(entry.untaken - bytes, 0)}
          %{state | pending: Map.put(state.pending, op_id, entry)}

        _ ->
          state
      end

    {:noreply, arm(state)}
  end

  @impl true
  def handle_info(:connect, %{socket: nil} = state) do
    case connect(state) do
      {:ok, socket} ->
        Process.send_after(self(), {:hello_timeout, socket}, @hello_timeout)
        {:noreply, %{state | socket: socket, armed: true}}

      {:error, reason} ->
        if state.alive?.() do
          {:noreply, retry_later(state)}
        else
          # Debug: whoever waits on a VM that's still starting asks again.
          Logger.debug(
            "the VM at #{state.path} isn't running (#{inspect(reason, printable_limit: 100)})"
          )

          {:stop, :normal, fail_all(state, "the environment's VM isn't running")}
        end
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = %{state | armed: false}

    state =
      case Channel.decode(data) do
        {:ok, frame} -> handle_frame(frame, state)
        {:error, :malformed} -> state
      end

    {:noreply, arm(state)}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, disconnected(state)}

  # A frame too large, a send that failed or timed out (which closes the
  # socket), or a socket that couldn't be read on.
  def handle_info({kind, socket, reason}, %{socket: socket} = state)
      when kind in [:tcp_error, :socket_failed] do
    state = warn(state, "the connection to the VM at #{state.path} failed: #{inspect(reason)}")
    {:noreply, disconnected(state)}
  end

  # Connected, but nothing in the guest answered: try again.
  def handle_info({:hello_timeout, socket}, %{socket: socket, ready: false} = state),
    do: {:noreply, disconnected(state)}

  def handle_info({:hello_timeout, _socket}, state), do: {:noreply, state}

  def handle_info({:query_timeout, id}, state) do
    case Map.pop(state.queries, id) do
      {{from, _q, _timer}, queries} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | queries: queries}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:run_timeout, op_id, ref}, state) do
    case state.pending do
      %{^op_id => %{ref: ^ref}} ->
        state = state |> finish(op_id, {:error, @timed_out}) |> cancel(op_id)
        {:noreply, arm(state)}

      _ ->
        {:noreply, state}
    end
  end

  # A caller that went away (its operation cancelled) takes its command
  # with it.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.pending, fn {_, e} -> e.monitor == monitor end) do
      {op_id, _} ->
        {_entry, state} = forget(state, op_id)
        {:noreply, state |> cancel(op_id) |> arm()}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Any step after the socket opens can fail; the socket goes with it.
  defp connect(state) do
    opts = [
      :binary,
      packet: :line,
      active: false,
      send_timeout: state.send_timeout,
      send_timeout_close: true
    ]

    with {:ok, socket} <- :gen_tcp.connect({:local, state.path}, 0, opts, @connect_timeout) do
      case open(socket, state) do
        :ok ->
          {:ok, socket}

        error ->
          :gen_tcp.close(socket)
          error
      end
    end
  end

  # Cloud Hypervisor's side of the socket answers OK once the guest has
  # accepted the connection on the port; then the link says hello.
  defp open(socket, state) do
    with :ok <- :gen_tcp.send(socket, "CONNECT #{Channel.port()}\n"),
         {:ok, "OK" <> _} <- :gen_tcp.recv(socket, 0, @connect_timeout),
         :ok <- :inet.setopts(socket, Channel.frame_opts(:host)),
         :ok <- Channel.send_frame(socket, hello(state), Channel.max_frame(:to_guest)) do
      :inet.setopts(socket, active: :once)
    else
      {:ok, line} -> {:error, {:handshake, line}}
      {:error, _} = error -> error
    end
  end

  defp hello(state), do: %{"t" => "hello", "now" => Channel.now(), "config" => state.config}

  defp disconnected(state) do
    :gen_tcp.close(state.socket)

    Enum.each(state.queries, fn {_id, {from, _q, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :disconnected})
    end)

    # A connection that stayed up starts the waits over.
    stable? = state.ready_at != nil and now() - state.ready_at >= state.max_retry
    backoff = if stable?, do: state.retry, else: state.backoff

    retry_later(%{
      state
      | socket: nil,
        armed: false,
        ready: false,
        ready_at: nil,
        queries: %{},
        backoff: backoff
    })
  end

  defp retry_later(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, state.max_retry)}
  end

  # Passes the guest's next frame on, unless a caller is behind on its log.
  defp arm(%{socket: nil} = state), do: state
  defp arm(%{armed: true} = state), do: state

  defp arm(state) do
    if Enum.any?(state.pending, fn {_, e} -> e.untaken > @log_window end) do
      state
    else
      case :inet.setopts(state.socket, active: :once) do
        :ok ->
          %{state | armed: true}

        {:error, reason} ->
          send(self(), {:socket_failed, state.socket, reason})
          state
      end
    end
  end

  defp handle_frame(%{"t" => "event", "event" => wire} = frame, state) do
    state = ack(state, frame["seq"])

    case Event.from_wire(wire) do
      {:ok, %Event{type: type} = event} when type in @op_events -> dispatch(event, state)
      _ -> state
    end
  end

  defp handle_frame(%{"t" => "reply", "id" => id} = frame, state) when is_integer(id) do
    case Map.pop(state.queries, id) do
      {{from, q, timer}, queries} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply(q, frame))
        %{state | queries: queries}

      {nil, _} ->
        state
    end
  end

  # The guest agent is there: everything waiting goes now (again, after a
  # reconnect to the same agent: it runs each op id once).
  defp handle_frame(
         %{"t" => "hello", "agent_version" => version, "instance" => instance},
         %{ready: false} = state
       )
       when is_binary(version) and is_binary(instance) do
    if instance?(instance) do
      state = if state.instance in [nil, instance], do: state, else: restarted(state)

      state = %{
        state
        | ready: true,
          ready_at: now(),
          instance: instance,
          guest_version: printable(version, 64)
      }

      state = Enum.reduce(state.cancels, %{state | cancels: MapSet.new()}, &cancel(&2, &1))
      Enum.reduce(Map.keys(state.pending), state, &send_cmd(&2, &1))
    else
      state
    end
  end

  defp handle_frame(_frame, state), do: state

  defp instance?(id), do: byte_size(id) in 1..64 and id =~ ~r/\A[A-Za-z0-9-]+\z/

  # A new guest agent hasn't heard of the commands the old one was sent,
  # and sending them again could run them twice. Ones it was never sent
  # (queued while the connection was down) go to the new one.
  defp restarted(state) do
    sent = for {op_id, %{sent_to: sent_to}} <- state.pending, sent_to != nil, do: op_id
    state = Enum.reduce(sent, state, &finish(&2, &1, {:error, @restarted}))
    %{state | cancels: MapSet.new()}
  end

  defp dispatch(%Event{type: "op.log", payload: p}, state) do
    case state.pending[p.op_id] do
      nil ->
        state

      %{over: true} ->
        state

      entry ->
        logged = entry.logged + byte_size(p.data)

        if logged > state.log_budget,
          do: pass_log(state, p.op_id, %{entry | over: true}, "info", @log_dropped),
          else: pass_log(state, p.op_id, %{entry | logged: logged}, p.stream, p.data)
    end
  end

  # Nobody waiting: dropped.
  defp dispatch(%Event{type: "op.result", payload: p}, state),
    do: finish(state, p.op_id, result(p))

  defp dispatch(%Event{type: "op.accepted"}, state), do: state

  defp pass_log(state, op_id, entry, stream, data) do
    send(entry.caller, {:link_log, entry.ref, stream, data})
    entry = %{entry | untaken: entry.untaken + byte_size(data)}
    %{state | pending: Map.put(state.pending, op_id, entry)}
  end

  defp result(%{status: "ok"} = p), do: {:ok, Map.get(p, :result, %{})}

  defp result(%{status: "error"} = p) do
    message = Map.get(p, :error) || "failed"

    case Map.get(p, :result, %{}) do
      empty when empty == %{} -> {:error, message}
      map -> {:error, message, map}
    end
  end

  defp reply(q, %{"ok" => true, "result" => result}) do
    if reply?(q, result) and :erlang.external_size(result) <= @max_reply,
      do: {:ok, result},
      else: {:error, @invalid_reply}
  end

  defp reply(_q, %{"error" => message}) when is_binary(message),
    do: {:error, printable(message, 1_000)}

  defp reply(_q, _frame), do: {:error, "failed"}

  # The shapes `ForemanAgent.Guest.queries/0` answer with; callers check
  # the rest.
  defp reply?("inventory", envs), do: is_list(envs) and Enum.all?(envs, &is_map/1)
  defp reply?("ports", ports), do: is_map(ports)
  defp reply?(_q, _result), do: false

  # Text from the guest: at most `max` bytes, valid UTF-8, and no control
  # characters.
  defp printable(text, max) do
    text
    |> binary_part(0, min(byte_size(text), max))
    |> Text.scrub()
    |> String.replace(~r/[[:cntrl:]]/u, "")
  end

  defp ack(state, seq) when is_integer(seq) and seq in 0..0xFFFFFFFFFFFFFFFF do
    {_, state} = send_frame(state, %{"t" => "ack", "seq" => seq})
    state
  end

  defp ack(state, _seq), do: state

  defp send_cmd(state, op_id) do
    %{cmd: cmd} = state.pending[op_id]
    frame = %{"t" => "cmd", "now" => Channel.now(), "cmd" => Command.to_wire(cmd)}

    case send_frame(state, frame) do
      {:ok, state} -> put_in(state.pending[op_id].sent_to, state.instance)
      {:too_large, state} -> finish(state, op_id, {:error, @too_large})
      {:failed, state} -> state
    end
  end

  # Cancels a command in the guest: now, or once the guest says hello.
  defp cancel(%{ready: true} = state, op_id) do
    case send_frame(state, %{"t" => "cancel", "op_id" => op_id}) do
      {:ok, state} -> state
      {_, state} -> cancel(state, op_id)
    end
  end

  defp cancel(state, op_id), do: %{state | cancels: MapSet.put(state.cancels, op_id)}

  # A send that fails leaves the link not ready straight away (so what
  # comes next waits for the next hello), and closes the connection once
  # the message is handled.
  defp send_frame(%{socket: nil} = state, _frame), do: {:failed, state}

  defp send_frame(%{socket: socket} = state, frame) do
    case Channel.send_frame(socket, frame, Channel.max_frame(:to_guest)) do
      :ok ->
        {:ok, state}

      {:error, :too_large} ->
        {:too_large, state}

      {:error, reason} ->
        send(self(), {:socket_failed, socket, reason})
        {:failed, %{state | ready: false}}
    end
  end

  # Takes a command off the list; its caller hears no more of it.
  defp forget(state, op_id) do
    case Map.pop(state.pending, op_id) do
      {nil, _} ->
        {nil, state}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        if entry.timer, do: Process.cancel_timer(entry.timer)
        {entry, %{state | pending: pending}}
    end
  end

  defp finish(state, op_id, result) do
    case forget(state, op_id) do
      {nil, state} ->
        state

      {entry, state} ->
        send(entry.caller, {:link_result, entry.ref, result})
        state
    end
  end

  defp fail_all(state, message) do
    state = Enum.reduce(Map.keys(state.pending), state, &finish(&2, &1, {:error, message}))

    Enum.each(state.queries, fn {_, {from, _q, _timer}} ->
      GenServer.reply(from, {:error, :not_running})
    end)

    %{state | queries: %{}}
  end

  defp warn(state, message) do
    now = now()

    if state.warned_at == nil or now - state.warned_at >= @warn_every do
      more = if state.unwarned > 0, do: " (and #{state.unwarned} more since the last)", else: ""
      Logger.warning(message <> more)
      %{state | warned_at: now, unwarned: 0}
    else
      %{state | unwarned: state.unwarned + 1}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
