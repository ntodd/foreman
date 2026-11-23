defmodule Foreman.Repo.Migrations.AddReadObservations do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :workspace_container_id, :string
    end

    alter table(:operations) do
      add :timeout_error, :text
    end

    # Both supported databases implement the ->> JSON text operator.
    execute """
            UPDATE environments SET workspace_container_id = (
              SELECT CASE WHEN status = 'succeeded' THEN result ->> 'container_id' END
              FROM operations WHERE environment_id = environments.id
                AND action IN ('create', 'start', 'rebuild', 'pull_rebuild', 'restart_affected', 'restart_all')
                AND finished_at IS NOT NULL AND dispatched_at IS NOT NULL
              ORDER BY dispatched_at DESC, id DESC LIMIT 1
            ) WHERE destroyed_at IS NULL
            """,
            "SELECT 1"

    execute """
            UPDATE operations SET timeout_error = error WHERE status = 'failed'
              AND CAST(args ->> 'timed_out' AS TEXT) IN ('true', '1')
            """,
            "SELECT 1"

    create index(:operations, [:environment_id, :inserted_at, :id])
    create index(:operations, [:finished_at], where: "finished_at IS NOT NULL")
    create index(:environments, [:user_id, :id], where: "destroyed_at IS NULL")
  end
end
