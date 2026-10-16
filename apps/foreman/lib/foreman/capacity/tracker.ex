defmodule Foreman.Capacity.Tracker do
  @moduledoc """
  Keeps the last 15 minutes of each box's stats in memory, for live usage
  and for the rolling average Foreman uses as an environment's
  provisioned size when it has no limits or hostRequirements.
  """
  use GenServer

  @window_seconds 15 * 60
  @table __MODULE__

  # Boxes report every 30 seconds. A report older than this is from a box
  # that has gone quiet, and isn't current usage any more.
  @fresh_seconds 120

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records a box.stats report."
  def record(box_id, stats, now \\ System.system_time(:second)) do
    :ets.insert(@table, {{:box, box_id}, now, stats})

    for {env_id, usage} <- stats.environments do
      :ets.insert(@table, {{:env, env_id, now}, usage})
    end

    :ok
  end

  @doc "The latest stats report from a box, or nil if it hasn't reported recently."
  def latest(box_id, now \\ System.system_time(:second)) do
    case :ets.lookup(@table, {:box, box_id}) do
      [{_, at, stats}] when at >= now - @fresh_seconds -> Map.put(stats, :at, at)
      _ -> nil
    end
  end

  @doc "An environment's average CPU percent and memory over the window, or nil with no samples."
  def average(env_id, now \\ System.system_time(:second)) do
    samples =
      :ets.select(@table, [
        {{{:env, env_id, :"$1"}, :"$2"}, [{:>=, :"$1", now - @window_seconds}], [:"$2"]}
      ])

    case samples do
      [] ->
        nil

      samples ->
        n = length(samples)

        %{
          cpu_percent: Enum.sum_by(samples, & &1.cpu_percent) / n,
          memory_mb: Enum.sum_by(samples, & &1.memory_mb) / n
        }
    end
  end

  @doc "An environment's latest usage, or nil if its box hasn't reported it recently."
  def latest_usage(env_id, now \\ System.system_time(:second)) do
    case :ets.select_reverse(
           @table,
           [
             {{{:env, env_id, :"$1"}, :"$2"}, [{:>=, :"$1", now - @fresh_seconds}],
              [{{:"$1", :"$2"}}]}
           ],
           1
         ) do
      {[{_at, usage}], _} -> usage
      _ -> nil
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :ordered_set,
      write_concurrency: true,
      read_concurrency: true
    ])

    Process.send_after(self(), :prune, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.system_time(:second) - @window_seconds
    :ets.select_delete(@table, [{{{:env, :_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :prune, 60_000)
    {:noreply, state}
  end
end
