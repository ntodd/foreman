defmodule Foreman.Operations.Retention do
  @moduledoc "Public lifecycle history and log windows, measured from operation completion."
  import Ecto.Query
  alias Foreman.Operations.Operation

  @actions ~w(create start stop destroy)
  def history_cutoff(now), do: DateTime.add(now, -90, :day)
  def log_cutoff(now), do: DateTime.add(now, -30, :day)

  def history(now) do
    from o in lifecycle(),
      where: is_nil(o.finished_at) or o.finished_at > ^history_cutoff(now)
  end

  def prune_history(now) do
    Foreman.Repo.delete_all(from o in lifecycle(), where: o.finished_at <= ^history_cutoff(now))
  end

  defp lifecycle do
    from o in Operation, where: not is_nil(o.environment_id) and o.action in ^@actions
  end
end
