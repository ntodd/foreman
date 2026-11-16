defmodule Foreman.Repo.Migrations.AddBoxRestart do
  use Ecto.Migration

  # Whether the box's agent can reboot it (box.restart, protocol 5), and
  # the boot it's on, which the command names.
  def change do
    alter table(:boxes) do
      add :can_restart, :boolean, null: false, default: false
      add :boot_id, :string
    end
  end
end
