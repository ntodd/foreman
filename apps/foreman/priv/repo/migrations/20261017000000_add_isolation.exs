defmodule Foreman.Repo.Migrations.AddIsolation do
  use Ecto.Migration

  # How a box runs environments, as its agent reports on join: "container"
  # (on the box's own Docker) or "vm" (each in its own VM). Environments
  # record which of the two they last came up in and, in a VM, its name
  # and size; null until one comes up under this release.
  def change do
    alter table(:boxes) do
      add :isolation, :string, null: false, default: "container"
    end

    alter table(:environments) do
      add :isolation, :string
      add :vm, :map
    end
  end
end
