defmodule Foreman.PublicAPI.Readiness do
  @moduledoc """
  Matches the container that finished devcontainer setup with a fresh guest
  observation from the connected agent. The channel owns the observation table,
  so a reconnect, even after an unclean disconnect, needs a new sample.
  """

  # Agents sample inventory every 15 seconds. Allow missed reports and query latency.
  @max_age_seconds 60

  def record(box_id, environments) do
    Registry.update_value(Foreman.Registry, {:agent, box_id}, fn table ->
      table = table || :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
      now = System.monotonic_time(:second)
      :ets.delete_all_objects(table)
      :ets.insert(table, Enum.map(environments, fn {id, running} -> {id, now, running} end))
      table
    end)

    :ok
  end

  def get(env) do
    case Registry.lookup(Foreman.Registry, {:agent, env.box_id}) do
      [] -> "unknown"
      [_] when not env.created_once or env.observed_state == "error" -> "not_ready"
      [{_, nil}] -> "unknown"
      [{_, table}] -> current(table, env)
    end
  end

  defp current(table, env) do
    cutoff = System.monotonic_time(:second) - @max_age_seconds

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
