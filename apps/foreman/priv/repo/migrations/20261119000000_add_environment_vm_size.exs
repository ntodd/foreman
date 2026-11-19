defmodule Foreman.Repo.Migrations.AddEnvironmentVmSize do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :vm_size, :map
    end
  end
end
