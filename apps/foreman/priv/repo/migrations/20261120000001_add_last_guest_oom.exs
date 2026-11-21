defmodule Foreman.Repo.Migrations.AddLastGuestOom do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :last_guest_oom_at, :utc_datetime
      add :last_guest_oom_processes, {:array, :string}, null: false, default: []
    end
  end
end
