defmodule Foreman.Repo.Migrations.RememberEnrollmentKey do
  use Ecto.Migration

  def change do
    alter table(:join_tokens) do
      add :enrollment_key_hash, :binary
    end
  end
end
