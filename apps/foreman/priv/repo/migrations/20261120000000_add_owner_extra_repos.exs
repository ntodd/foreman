defmodule Foreman.Repo.Migrations.AddOwnerExtraRepos do
  use Ecto.Migration

  # Repos every one of the owner's repos' scoped tokens reach, on top of
  # each repo's own extra repos.
  def change do
    alter table(:owners) do
      add :extra_repos, {:array, :string}, null: false, default: []
    end
  end
end
