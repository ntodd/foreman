defmodule Foreman.Repo.Migrations.CreatePrebuilds do
  use Ecto.Migration

  # A repo's environment disk, built once on a box for a branch and
  # devcontainer config; new environments there start from it.
  def change do
    create table(:prebuilds) do
      add :repo_id, references(:repos, on_delete: :delete_all), null: false
      add :box_id, references(:boxes, on_delete: :delete_all), null: false
      add :branch, :string, null: false
      add :config_path, :string, null: false
      # The repos it was built able to read (the repo and its extra repos
      # then): whoever starts from it has to be able to read them all.
      add :repos, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "building"
      add :error, :text
      add :size_mb, :integer
      add :op_id, :binary_id
      add :built_at, :utc_datetime_usec
      timestamps()
    end

    create index(:prebuilds, [:repo_id, :box_id])
    create index(:prebuilds, [:op_id])
  end
end
