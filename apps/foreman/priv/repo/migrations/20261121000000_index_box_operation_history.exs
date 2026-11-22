defmodule Foreman.Repo.Migrations.IndexBoxOperationHistory do
  use Ecto.Migration

  def change do
    create index(:operations, [:box_id, :inserted_at], where: "environment_id IS NULL")
  end
end
