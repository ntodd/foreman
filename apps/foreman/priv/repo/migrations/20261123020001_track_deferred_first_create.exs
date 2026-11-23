defmodule Foreman.Repo.Migrations.TrackDeferredFirstCreate do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :initial_create_deferred, :boolean, default: false, null: false
    end
  end
end
