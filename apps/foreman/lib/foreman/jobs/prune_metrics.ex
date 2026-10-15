defmodule Foreman.Jobs.PruneMetrics do
  @moduledoc "Drops box and environment metrics older than seven days."
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl true
  def perform(_job) do
    Foreman.Metrics.prune()
    :ok
  end
end
