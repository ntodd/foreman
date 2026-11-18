defmodule Foreman.Repo.Migrations.AddBoxReboot do
  use Ecto.Migration

  # Whether each box needs a reboot, as its agent reports it: the flag,
  # the packages that asked for it, and whether a livepatch is applied to
  # the running kernel. Null until an agent that reports it joins.
  def change do
    alter table(:boxes) do
      add :reboot_required, :boolean
      add :reboot_packages, {:array, :string}, null: false, default: []
      add :livepatch, :boolean
    end
  end
end
