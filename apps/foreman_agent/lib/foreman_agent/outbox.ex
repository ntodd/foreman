defmodule ForemanAgent.Outbox do
  @moduledoc """
  Holds events for the control plane while the socket is down.

  Operations keep running when the connection drops, so their events
  queue here until the next connection attaches. Results (`op.result`)
  are kept until the control plane acknowledges them and are redelivered
  on every attach until then. Logs are best effort: past `max_logs`, the
  oldest are dropped.

  The attached connection receives `{:outbox_deliver, event, ack_id}`;
  `ack_id` is nil for events that need no acknowledgement.
  """
  use GenServer

  alias ForemanProtocol.Event

  @reliable ["op.result"]

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def push(server \\ __MODULE__, %Event{} = event), do: GenServer.cast(server, {:push, event})
  def attach(server \\ __MODULE__, pid), do: GenServer.call(server, {:attach, pid})
  def detach(server \\ __MODULE__), do: GenServer.call(server, :detach)
  def ack(server \\ __MODULE__, ack_id), do: GenServer.cast(server, {:ack, ack_id})

  @impl true
  def init(opts) do
    {:ok,
     %{
       conn: nil,
       monitor: nil,
       # Unsent events, oldest first, as {seq, event}.
       pending: :queue.new(),
       logs: 0,
       max_logs: Keyword.get(opts, :max_logs, 5_000),
       # Reliable events sent but not acked: seq => event.
       unacked: %{},
       seq: 0
     }}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    seq = state.seq + 1
    state = %{state | seq: seq}

    if state.conn do
      {:noreply, deliver(state, seq, event)}
    else
      {:noreply, enqueue(state, seq, event)}
    end
  end

  def handle_cast({:ack, seq}, state),
    do: {:noreply, %{state | unacked: Map.delete(state.unacked, seq)}}

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    state = demonitor(state)
    state = %{state | conn: pid, monitor: Process.monitor(pid)}

    # Unacked results first (they're older), then everything queued.
    state =
      state.unacked
      |> Enum.sort()
      |> Enum.reduce(state, fn {seq, event}, acc -> deliver(acc, seq, event) end)

    pending = :queue.to_list(state.pending)
    state = %{state | pending: :queue.new(), logs: 0}
    state = Enum.reduce(pending, state, fn {seq, event}, acc -> deliver(acc, seq, event) end)
    {:reply, :ok, state}
  end

  def handle_call(:detach, _from, state),
    do: {:reply, :ok, state |> demonitor() |> Map.put(:conn, nil)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, %{state | conn: nil, monitor: nil}}
  end

  def handle_info({:DOWN, _, _, _, _}, state), do: {:noreply, state}

  defp deliver(state, seq, %Event{type: type} = event) when type in @reliable do
    send(state.conn, {:outbox_deliver, event, seq})
    %{state | unacked: Map.put(state.unacked, seq, event)}
  end

  defp deliver(state, _seq, event) do
    send(state.conn, {:outbox_deliver, event, nil})
    state
  end

  defp enqueue(state, seq, %Event{type: type} = event) when type in @reliable do
    %{state | pending: :queue.in({seq, event}, state.pending)}
  end

  defp enqueue(state, seq, %Event{type: "op.log"} = event) do
    state = %{state | pending: :queue.in({seq, event}, state.pending), logs: state.logs + 1}
    if state.logs > state.max_logs, do: drop_oldest_log(state), else: state
  end

  # Inventory, stats and state events are snapshots; only the latest of
  # each type matters once the connection is back.
  defp enqueue(state, seq, %Event{type: type} = event) do
    pending = :queue.filter(fn {_, e} -> e.type != type or type == "env.state" end, state.pending)
    %{state | pending: :queue.in({seq, event}, pending)}
  end

  defp drop_oldest_log(state) do
    list = :queue.to_list(state.pending)
    index = Enum.find_index(list, fn {_, e} -> e.type == "op.log" end)
    %{state | pending: list |> List.delete_at(index) |> :queue.from_list(), logs: state.logs - 1}
  end

  defp demonitor(%{monitor: nil} = state), do: state

  defp demonitor(state) do
    Process.demonitor(state.monitor, [:flush])
    %{state | monitor: nil}
  end
end
