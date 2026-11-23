defmodule Foreman.Repo.Migrations.TrackWorkloadGrant do
  use Ecto.Migration

  def change do
    alter table(:environments), do: add(:workload_grant_id, :binary_id)
  end
end
