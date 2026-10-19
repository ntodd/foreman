defmodule Foreman.Repo.Migrations.AddFeatureVersions do
  use Ecto.Migration

  # The Foreman feature a box's agent installs, and the one each
  # environment's container was built with.
  def change do
    alter table(:boxes) do
      add :feature_version, :string
    end

    alter table(:environments) do
      add :feature_version, :string
    end
  end
end
