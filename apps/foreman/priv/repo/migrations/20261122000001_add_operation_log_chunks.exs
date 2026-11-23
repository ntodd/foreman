defmodule Foreman.Repo.Migrations.AddOperationLogChunks do
  use Ecto.Migration

  def change do
    create table(:operation_log_chunks, primary_key: false) do
      add :operation_id, references(:operations, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :end_offset, :bigint, primary_key: true
      add :data, :binary, null: false
    end
  end
end
