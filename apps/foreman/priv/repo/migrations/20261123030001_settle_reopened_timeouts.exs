defmodule Foreman.Repo.Migrations.SettleReopenedTimeouts do
  use Ecto.Migration

  def up do
    # Older agents could acknowledge a command after housekeeping finished it.
    # Keep the marker so its eventual physical result can still be reconciled.
    execute """
    UPDATE operations
       SET status = 'failed',
           error = COALESCE(timeout_error, error),
           timeout_error = COALESCE(timeout_error, error)
     WHERE status IN ('queued', 'dispatched', 'running')
       AND finished_at IS NOT NULL
       AND CAST(args ->> 'timed_out' AS TEXT) IN ('true', '1')
    """
  end

  def down, do: :ok
end
