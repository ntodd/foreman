defmodule Foreman.Metrics.EnvMetric do
  @moduledoc "One environment's CPU and memory at a point in time."
  use Ecto.Schema

  @primary_key false
  schema "env_metrics" do
    field :box_id, :binary_id
    field :env_id, :binary_id
    field :slug, :string
    field :at, :integer
    field :cpu_percent, :float
    field :memory_mb, :integer
  end
end
