defmodule Foreman.Repo.Migrations.SplitBoxContentionThreshold do
  use Ecto.Migration

  # CPU and memory overcommit carry different risks with environment
  # VMs, so a box gets a threshold for each. Both start at the box's
  # current threshold.
  def up do
    rename table(:boxes), :contention_threshold, to: :cpu_threshold

    alter table(:boxes) do
      add :memory_threshold, :float, null: false, default: 0.9
    end

    flush()
    execute "UPDATE boxes SET memory_threshold = cpu_threshold"
  end

  def down do
    alter table(:boxes) do
      remove :memory_threshold
    end

    rename table(:boxes), :cpu_threshold, to: :contention_threshold
  end
end
