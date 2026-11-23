defmodule Foreman.Repo.Migrations.AddAccessGeneration do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :access_generation, :bigint, null: false, default: 0
    end
  end
end
