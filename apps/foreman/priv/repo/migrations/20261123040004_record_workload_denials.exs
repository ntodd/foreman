defmodule Foreman.Repo.Migrations.RecordWorkloadDenials do
  use Ecto.Migration

  def change do
    alter table(:operations), do: add(:workload_denied, :boolean, default: false, null: false)

    execute(
      """
      UPDATE operations SET workload_denied = TRUE, timeout_error = NULL
      WHERE timeout_error = 'Workload authorization is no longer valid.'
         OR (dispatched_at IS NULL AND error = 'Workload authorization is no longer valid.')
      """,
      "SELECT 1"
    )
  end
end
