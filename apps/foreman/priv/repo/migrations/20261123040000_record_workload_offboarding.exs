defmodule Foreman.Repo.Migrations.RecordWorkloadOffboarding do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :workload_access_revoked_at, :utc_datetime_usec
      add :ssh_removal_id, :binary_id
    end

    # Prior releases recorded confirmed departures and subsequent successful
    # sign-ins in the audit log. An expired GitHub login alone proves neither.
    execute(
      """
      WITH history AS (
        SELECT subject_id,
          MAX(CASE WHEN action = 'user.access_revoked' THEN inserted_at END) AS revoked,
          MAX(CASE WHEN action = 'user.sign_in' THEN inserted_at END) AS signed_in
        FROM audit_events
        WHERE subject_type = 'User' AND action IN ('user.access_revoked', 'user.sign_in')
        GROUP BY subject_id
      )
      UPDATE users SET workload_access_revoked_at = history.revoked
      FROM history WHERE history.subject_id = CAST(users.id AS varchar)
        AND history.revoked IS NOT NULL AND (history.signed_in IS NULL OR history.revoked >= history.signed_in)
      """,
      "SELECT 1"
    )

    execute(
      """
      UPDATE users SET ssh_removal_id = id
      WHERE (disabled_at IS NOT NULL OR workload_access_revoked_at IS NOT NULL) AND EXISTS (
        SELECT 1 FROM environments WHERE destroyed_at IS NULL AND tailscale_device_id IS NOT NULL
      )
      """,
      "SELECT 1"
    )
  end
end
