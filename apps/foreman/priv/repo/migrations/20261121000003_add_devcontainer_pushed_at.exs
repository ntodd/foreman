defmodule Foreman.Repo.Migrations.AddDevcontainerPushedAt do
  use Ecto.Migration

  def change do
    alter table(:repos) do
      add :devcontainer_pushed_at, :string
    end
  end
end
