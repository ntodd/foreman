defmodule Foreman.Repo.Migrations.SnapshotRepositoryBindings do
  use Ecto.Migration
  import Ecto.Query

  def change do
    alter table(:environments) do
      add :repo_github_id, :bigint
    end

    create table(:oauth_grant_repositories, primary_key: false) do
      add :grant_id, references(:oauth_grants, on_delete: :delete_all), primary_key: true
      add :repo_id, references(:repos, on_delete: :delete_all), primary_key: true
      add :github_id, :bigint
    end

    # Rows originally created with the numeric ID have unambiguous provenance.
    # A later binding timestamp cannot establish which identity a concurrent
    # creator saw. Those legacy workspaces and approvals remain unverified.
    execute(
      """
      UPDATE environments SET repo_github_id = (
        SELECT r.github_id FROM repos r WHERE r.id = environments.repo_id
          AND r.github_identity_bound_at IS NULL
      )
      """,
      "SELECT 1"
    )

    execute(
      fn ->
        bindings =
          from(g in "oauth_grants",
            join: r in "repos",
            on: type(r.id, :string) in g.repo_ids,
            where: is_nil(r.github_identity_bound_at),
            select: %{grant_id: g.id, repo_id: r.id, github_id: r.github_id}
          )

        repo().insert_all("oauth_grant_repositories", bindings)
      end,
      fn -> :ok end
    )
  end
end
