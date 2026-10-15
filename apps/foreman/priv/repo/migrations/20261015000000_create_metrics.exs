defmodule Foreman.Repo.Migrations.CreateMetrics do
  use Ecto.Migration

  # Time series for the box charts, pruned after seven days. `at` is Unix
  # seconds so bucketing is plain integer math on SQLite and Postgres.
  # Environment samples keep the slug and no foreign key, so a destroyed
  # environment's history stays on its box's charts until it ages out.
  def change do
    create table(:box_metrics, primary_key: false) do
      add :box_id, references(:boxes, on_delete: :delete_all), null: false
      add :at, :bigint, null: false
      add :cpu_percent, :float, null: false
      add :load1, :float, null: false, default: 0.0
      add :memory_used_mb, :integer, null: false
      add :memory_total_mb, :integer, null: false
      add :swap_used_mb, :integer, null: false, default: 0
      add :swap_total_mb, :integer, null: false, default: 0
      add :disk_used_mb, :integer, null: false
      add :disk_total_mb, :integer, null: false
    end

    create index(:box_metrics, [:box_id, :at])
    create index(:box_metrics, [:at])

    create table(:env_metrics, primary_key: false) do
      add :box_id, references(:boxes, on_delete: :delete_all), null: false
      add :env_id, :binary_id, null: false
      add :slug, :string, null: false
      add :at, :bigint, null: false
      add :cpu_percent, :float, null: false
      add :memory_mb, :integer, null: false
    end

    create index(:env_metrics, [:box_id, :at])
    create index(:env_metrics, [:at])
  end
end
