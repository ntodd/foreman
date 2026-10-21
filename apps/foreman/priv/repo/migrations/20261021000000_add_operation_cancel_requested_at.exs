defmodule Foreman.Repo.Migrations.AddOperationCancelRequestedAt do
  use Ecto.Migration

  # When someone asked for a dispatched operation to stop. The op.cancel
  # can be lost with the connection, so a resend after a reconnect sends
  # the cancel again rather than the operation. Its own column, so setting
  # it can't race other writers of args.
  def change do
    alter table(:operations) do
      add :cancel_requested_at, :utc_datetime_usec
    end
  end
end
