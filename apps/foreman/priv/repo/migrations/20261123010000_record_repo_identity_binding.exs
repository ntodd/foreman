defmodule Foreman.Repo.Migrations.RecordRepoIdentityBinding do
  use Ecto.Migration
  import Ecto.Query

  def change do
    alter table(:repos) do
      add :github_identity_bound_at, :utc_datetime_usec
    end

    # Legacy manual rows may have acquired their GitHub ID after a workspace
    # or service grant had already been created under the same name.
    execute(
      fn ->
        now = DateTime.utc_now()

        query =
          from(r in "repos",
            where: r.manual == true and not is_nil(r.github_id),
            update: [set: [github_identity_bound_at: type(^now, :utc_datetime_usec)]]
          )

        repo().update_all(query, [])
      end,
      fn -> :ok end
    )
  end
end
