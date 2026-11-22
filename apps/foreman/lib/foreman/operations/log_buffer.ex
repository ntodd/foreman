defmodule Foreman.Operations.LogBuffer do
  @moduledoc """
  Collects operation log chunks, broadcasts them, and writes them to the
  database in batches, so a chatty build doesn't become a write per line.
  Each operation keeps at most the last #{div(1_048_576, 1024)} KiB.

  Text is scrubbed of the environment's secrets before it's broadcast or
  stored. Chunks are raw pipe reads, so a secret can straddle two of
  them; redacting each chunk on its own would let it through. Text is
  therefore redacted a whole line at a time: the unfinished line at the
  end of a chunk is held back and joined to the next one. It's let out
  anyway when the operation's log is flushed, when it has sat for
  #{500} ms (a prompt, say), or when it grows past #{div(65_536, 1024)} KiB without a
  newline.
  """
  use GenServer

  alias Foreman.Operations.{LogStore, Redactions}

  @flush_every 750
  @hold_partial_ms 500
  @max_partial 65_536

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def append(op_id, data), do: GenServer.cast(__MODULE__, {:append, op_id, data})

  @doc "Text received but not written yet. A held-back partial line isn't included."
  def pending(op_id), do: GenServer.call(__MODULE__, {:pending, op_id})

  def snapshot(op_id) do
    case GenServer.call(__MODULE__, {:snapshot, op_id}, :infinity) do
      {:ok, log, cursor} -> {log, cursor}
      {:error, error} -> raise error
    end
  end

  @doc "Lets out the operation's held-back partial line and writes everything."
  def flush(op_id), do: GenServer.call(__MODULE__, {:flush, op_id})

  @impl true
  def init(_) do
    Process.send_after(self(), :flush, @flush_every)
    # chunks: op_id => redacted text not written yet (newest first)
    # partial: op_id => {raw tail, already masked prefix length, last extended at}
    {:ok, %{chunks: %{}, partial: %{}}}
  end

  @impl true
  def handle_cast({:append, op_id, data}, state) do
    {held, covered, state} = pop_partial(state, op_id)
    text = held <> data
    {:noreply, release(state, op_id, text, line_cut(text), covered)}
  end

  @impl true
  def handle_call({:pending, op_id}, _from, state) do
    {:reply, state.chunks |> Map.get(op_id, []) |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  def handle_call({:snapshot, op_id}, _from, state) do
    pending = state.chunks |> Map.get(op_id, []) |> Enum.reverse()
    {:reply, {:ok, LogStore.read(op_id, pending), sequence()}, state}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call({:flush, op_id}, _from, state) do
    {held, covered, state} = pop_partial(state, op_id)
    state = release(state, op_id, held, byte_size(held), covered, true)
    {chunks, state} = pop_in(state.chunks[op_id])
    if chunks, do: write(op_id, chunks)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    cutoff = now() - @hold_partial_ms
    {stale, fresh} = Enum.split_with(state.partial, fn {_, {_, _, at}} -> at <= cutoff end)

    # A prompt waiting for input is shown, up to anything that could be the
    # start of a secret, which waits for the next read.
    state =
      Enum.reduce(stale, %{state | partial: Map.new(fresh)}, fn {op_id, {held, covered, _}},
                                                                acc ->
        release(acc, op_id, held, byte_size(held), covered)
      end)

    Enum.each(state.chunks, fn {op_id, chunks} -> write(op_id, chunks) end)
    Process.send_after(self(), :flush, @flush_every)
    {:noreply, %{state | chunks: %{}}}
  end

  defp release(state, op_id, text, cut, covered, final? \\ false) do
    {shown, kept, covered} = Redactions.split(op_id, text, cut, covered)

    if final? do
      shown = if kept != "" and covered == 0, do: shown <> "[redacted]", else: shown
      emit(state, op_id, shown)
    else
      state = emit(state, op_id, shown)

      if kept == "",
        do: state,
        else: put_in(state.partial[op_id], {:binary.copy(kept), covered, now()})
    end
  rescue
    # Reconstructing secret values may need the database after a restart.
    _ -> state
  end

  defp pop_partial(state, op_id) do
    case Map.pop(state.partial, op_id) do
      {{held, covered, _at}, partial} -> {held, covered, %{state | partial: partial}}
      {nil, _} -> {"", 0, state}
    end
  end

  # Release complete lines and overlong partial lines.
  defp line_cut(text) do
    last =
      case List.last(:binary.matches(text, ["\n", "\r"])) do
        nil -> 0
        {pos, 1} -> pos + 1
      end

    if byte_size(text) - last > @max_partial, do: byte_size(text), else: last
  end

  defp emit(state, _op_id, ""), do: state

  defp emit(state, op_id, text) do
    Phoenix.PubSub.broadcast(
      Foreman.PubSub,
      "operation:" <> op_id,
      {:op_log, op_id, sequence(), text}
    )

    %{state | chunks: Map.update(state.chunks, op_id, [text], &[text | &1])}
  end

  defp sequence, do: System.unique_integer([:positive, :monotonic])

  defp now, do: System.monotonic_time(:millisecond)

  defp write(op_id, chunks) do
    new = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    LogStore.append(op_id, new)
  rescue
    # A write that fails (the operation's environment was just deleted, the
    # database busy past its timeout) shouldn't take the buffer down, and
    # with it every other operation's unwritten log.
    _ -> :ok
  catch
    # A connection that goes away mid-query exits rather than raises.
    :exit, _ -> :ok
  end
end
