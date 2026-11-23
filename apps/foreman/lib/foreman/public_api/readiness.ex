defmodule Foreman.PublicAPI.Readiness do
  @moduledoc """
  Matches the container that finished devcontainer setup with a fresh guest
  observation from the connected agent. The channel owns the observation table,
  so a reconnect, even after an unclean disconnect, needs a new sample.
  """

  # Agents sample inventory every 15 seconds. Allow missed reports and query latency.
  @max_age_ms 60_000

  def record(box_id, environments, since_join_ms) do
    Registry.update_value(Foreman.Registry, {:agent, box_id}, fn {joined_at, table} ->
      table = table || :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
      # The box measures scan start relative to receiving the join. Our join
      # started earlier, so collection and transit time consume the freshness window.
      sampled_at = min(System.monotonic_time(:millisecond), joined_at + since_join_ms)
      :ets.delete_all_objects(table)

      :ets.insert(
        table,
        Enum.map(environments, fn {id, running} -> {id, sampled_at, running} end)
      )

      {joined_at, table}
    end)

    :ok
  end

  def get(env) do
    case Registry.lookup(Foreman.Registry, {:agent, env.box_id}) do
      [] -> "unknown"
      [_] when not env.created_once or env.observed_state == "error" -> "not_ready"
      [{_, {_, table}}] when not is_nil(table) -> current(table, env)
      [_] -> "unknown"
    end
  end

  defp current(table, env) do
    cutoff = System.monotonic_time(:millisecond) - @max_age_ms

    case :ets.lookup(table, env.id) do
      [{_, at, ids}] when at >= cutoff ->
        cond do
          env.observed_state not in ["running", "partial"] -> "not_ready"
          ids == [] or not env.created_once -> "not_ready"
          is_nil(env.workspace_container_id) -> "unknown"
          env.workspace_container_id in ids -> "ready"
          true -> "not_ready"
        end

      _ ->
        "unknown"
    end
  rescue
    # The channel disconnected after the registry lookup.
    ArgumentError -> "unknown"
  end
end
