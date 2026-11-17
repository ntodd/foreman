defmodule Foreman.Repo.Migrations.SplitBoxContentionThreshold do
  use Ecto.Migration

  # CPU and memory overcommit carry different risks with environment
  # VMs, so a box gets a threshold for each. Both start at the box's
  # current threshold.
  #
  # contention_threshold stays, unused, so the release before this one
  # still reads it after a rollback (with the value it had at upgrade). A
  # later release drops it.
  def up do
    alter table(:boxes) do
      add :cpu_threshold, :float, null: false, default: 0.9
      add :memory_threshold, :float, null: false, default: 0.9
    end

    flush()

    execute "UPDATE boxes SET cpu_threshold = contention_threshold, memory_threshold = contention_threshold"
  end

  def down do
    alter table(:boxes) do
      remove :cpu_threshold
      remove :memory_threshold
    end
  end
end
