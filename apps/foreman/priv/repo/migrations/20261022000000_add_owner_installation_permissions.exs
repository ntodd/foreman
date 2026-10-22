defmodule Foreman.Repo.Migrations.AddOwnerInstallationPermissions do
  use Ecto.Migration

  # What the GitHub App's installation on this account was granted, from
  # each sync. Environment tokens never ask for more.
  def change do
    alter table(:owners) do
      add :installation_permissions, :map
    end
  end
end
