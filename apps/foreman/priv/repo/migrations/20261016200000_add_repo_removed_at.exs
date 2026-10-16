defmodule Foreman.Repo.Migrations.AddRepoRemovedAt do
  use Ecto.Migration

  # When a sync last saw a repo missing from its installation (removed
  # from the app, deleted, or transferred away). Hidden from the repo list
  # while set; existing environments keep working.
  def change do
    alter table(:repos) do
      add :removed_at, :utc_datetime_usec
    end

    create index(:repos, [:github_id])
  end
end
