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

  import Ecto.Query

  alias Foreman.Operations.{Operation, Redactions}
  alias Foreman.Repo

  @flush_every 750
  @hold_partial_ms 500
  @max_partial 65_536
  @max_log 1_048_576

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def append(op_id, data), do: GenServer.cast(__MODULE__, {:append, op_id, data})

  @doc "Text received but not written yet. A held-back partial line isn't included."
  def pending(op_id), do: GenServer.call(__MODULE__, {:pending, op_id})

  @doc "Lets out the operation's held-back partial line and writes everything."
  def flush(op_id), do: GenServer.call(__MODULE__, {:flush, op_id})

  @impl true
  def init(_) do
    Process.send_after(self(), :flush, @flush_every)
    # chunks: op_id => redacted text not written yet (newest first)
    # partial: op_id => {unredacted unfinished line, when it was last extended}
    {:ok, %{chunks: %{}, partial: %{}}}
  end

  @impl true
  def handle_cast({:append, op_id, data}, state) do
    {held, state} = pop_partial(state, op_id)
    {ready, rest} = split_lines(held <> data)

    # A line too long to hold goes out, but not a tail that could be the
    # start of a secret.
    {ready, rest} = if rest == "", do: hold_back(op_id, ready), else: {ready, rest}

    {:noreply, state |> emit(op_id, ready) |> hold(op_id, rest)}
  end

  @impl true
  def handle_call({:pending, op_id}, _from, state) do
    {:reply, state.chunks |> Map.get(op_id, []) |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  def handle_call({:flush, op_id}, _from, state) do
    {held, state} = pop_partial(state, op_id)
    # The start of a secret whose rest never came is still part of it.
    {shown, cut} = hold_back(op_id, held)
    state = emit(state, op_id, shown <> if(cut == "", do: "", else: "[redacted]"))
    {chunks, state} = pop_in(state.chunks[op_id])
    if chunks, do: write(op_id, chunks)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    cutoff = now() - @hold_partial_ms
    {stale, fresh} = Enum.split_with(state.partial, fn {_, {_, at}} -> at <= cutoff end)

    # A prompt waiting for input is shown, up to anything that could be the
    # start of a secret, which waits for the next read.
    state =
      Enum.reduce(stale, %{state | partial: Map.new(fresh)}, fn {op_id, {held, _}}, acc ->
        {shown, kept} = hold_back(op_id, held)
        acc |> emit(op_id, shown) |> hold(op_id, kept)
      end)

    Enum.each(state.chunks, fn {op_id, chunks} -> write(op_id, chunks) end)
    Process.send_after(self(), :flush, @flush_every)
    {:noreply, %{state | chunks: %{}}}
  end

  defp hold(state, _op_id, ""), do: state
  defp hold(state, op_id, text), do: put_in(state.partial[op_id], {text, now()})

  defp hold_back(op_id, text) do
    Redactions.hold_back(op_id, text)
  rescue
    _ -> {text, ""}
  end

  defp pop_partial(state, op_id) do
    case Map.pop(state.partial, op_id) do
      {{held, _at}, partial} -> {held, %{state | partial: partial}}
      {nil, _} -> {"", state}
    end
  end

  # Splits after the last line ending ("\r" too, for progress output). An
  # unfinished line too long to hold goes out whole.
  defp split_lines(text) do
    case :binary.matches(text, ["\n", "\r"]) do
      [] when byte_size(text) > @max_partial ->
        {text, ""}

      [] ->
        {"", text}

      matches ->
        {pos, 1} = List.last(matches)
        cut = pos + 1
        rest = binary_part(text, cut, byte_size(text) - cut)

        if byte_size(rest) > @max_partial,
          do: {text, ""},
          else: {binary_part(text, 0, cut), rest}
    end
  end

  defp emit(state, _op_id, ""), do: state

  defp emit(state, op_id, text) do
    text = Redactions.redact(op_id, text)
    Phoenix.PubSub.broadcast(Foreman.PubSub, "operation:" <> op_id, {:op_log, op_id, text})
    %{state | chunks: Map.update(state.chunks, op_id, [text], &[text | &1])}
  rescue
    # Redaction can need the database (after a restart); a failure there
    # drops this text rather than the buffer, and never shows it unscrubbed.
    _ -> state
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp write(op_id, chunks) do
    new = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case Repo.one(from o in Operation, where: o.id == ^op_id, select: {o.log, o.log_truncated}) do
      {existing, truncated} ->
        combined = (existing || "") <> new

        {log, truncated} =
          if byte_size(combined) > @max_log,
            do: {binary_part(combined, byte_size(combined) - @max_log, @max_log), true},
            else: {combined, truncated}

        Repo.update_all(from(o in Operation, where: o.id == ^op_id),
          set: [log: scrub(log), log_truncated: truncated]
        )

      nil ->
        :ok
    end
  rescue
    # A write that fails (the operation's environment was just deleted, the
    # database busy past its timeout) shouldn't take the buffer down, and
    # with it every other operation's unwritten log.
    _ -> :ok
  catch
    # A connection that goes away mid-query exits rather than raises.
    :exit, _ -> :ok
  end

  # Trimming can split a UTF-8 sequence at the start.
  defp scrub(log), do: if(String.valid?(log), do: log, else: String.replace_invalid(log))
end
