defmodule Foreman.Repo.Migrations.RecordRepoIdentityBinding do
  use Ecto.Migration

  def change do
    alter table(:repos) do
      add :github_identity_bound_at, :utc_datetime_usec
    end
  end
end
