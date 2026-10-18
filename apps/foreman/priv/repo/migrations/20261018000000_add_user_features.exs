defmodule Foreman.Repo.Migrations.AddUserFeatures do
  use Ecto.Migration

  # Devcontainer features a user adds to all their own environments, in
  # devcontainer.json's shape (ref => options), and the ones they turn off
  # for a repo (by ref, without a version).
  def change do
    alter table(:users) do
      add :devcontainer_features, :map, null: false, default: %{}
    end

    alter table(:user_repo_settings) do
      add :disabled_features, {:array, :string}, null: false, default: []
    end
  end
end
