defmodule Foreman.Metrics.BoxMetric do
  @moduledoc "One host-wide sample from a box's agent."
  use Ecto.Schema

  @primary_key false
  schema "box_metrics" do
    field :box_id, :binary_id
    field :at, :integer
    field :cpu_percent, :float
    field :load1, :float
    field :memory_used_mb, :integer
    field :memory_total_mb, :integer
    field :swap_used_mb, :integer
    field :swap_total_mb, :integer
    field :disk_used_mb, :integer
    field :disk_total_mb, :integer
  end
end
