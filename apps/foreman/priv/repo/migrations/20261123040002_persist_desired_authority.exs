defmodule Foreman.Repo.Migrations.PersistDesiredAuthority do
  use Ecto.Migration

  def change do
    alter table(:environments), do: add(:desired_authority, :map)
  end
end
