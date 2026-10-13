defmodule Foreman.Operations.LogBuffer do
  @moduledoc """
  Collects operation log chunks, broadcasts each as it arrives, and writes
  them to the database in batches, so a chatty build doesn't become a
  write per line. Each operation keeps at most the last #{div(1_048_576, 1024)} KiB.
  """
  use GenServer

  import Ecto.Query

  alias Foreman.Operations.Operation
  alias Foreman.Repo

  @flush_every 750
  @max_log 1_048_576

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def append(op_id, data) do
    Phoenix.PubSub.broadcast(Foreman.PubSub, "operation:" <> op_id, {:op_log, op_id, data})
    GenServer.cast(__MODULE__, {:append, op_id, data})
  end

  def pending(op_id), do: GenServer.call(__MODULE__, {:pending, op_id})

  def flush(op_id), do: GenServer.call(__MODULE__, {:flush, op_id})

  @impl true
  def init(_) do
    Process.send_after(self(), :flush, @flush_every)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:append, op_id, data}, state) do
    {:noreply, Map.update(state, op_id, [data], &[data | &1])}
  end

  @impl true
  def handle_call({:pending, op_id}, _from, state) do
    {:reply, state |> Map.get(op_id, []) |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  def handle_call({:flush, op_id}, _from, state) do
    {chunks, state} = Map.pop(state, op_id)
    if chunks, do: write(op_id, chunks)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    Enum.each(state, fn {op_id, chunks} -> write(op_id, chunks) end)
    Process.send_after(self(), :flush, @flush_every)
    {:noreply, %{}}
  end

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
    # sandbox owner exited in tests) shouldn't take the buffer down.
    _ -> :ok
  end

  # Trimming can split a UTF-8 sequence at the start.
  defp scrub(log), do: if(String.valid?(log), do: log, else: String.replace_invalid(log))
end
