defmodule Foreman.Repo.Migrations.AddBoxVm do
  use Ecto.Migration

  # Whether the box can run environment VMs (protocol 6's join `vm`):
  # ready, the reason when it isn't, nested, reflink.
  def change do
    alter table(:boxes) do
      add :vm, :map
    end
  end
end
