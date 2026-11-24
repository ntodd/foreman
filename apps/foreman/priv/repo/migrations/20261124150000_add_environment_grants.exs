defmodule Foreman.Repo.Migrations.AddEnvironmentGrants do
  use Ecto.Migration

  def change do
    alter table(:oauth_grants), do: add(:environment_id, :binary_id)

    # One live grant an environment: a second request racing the first
    # inserts nothing and reads the first one's row.
    create unique_index(:oauth_grants, [:environment_id],
             where: "environment_id IS NOT NULL AND revoked_at IS NULL",
             name: :oauth_grants_live_environment_index
           )

    # The nonce of every relayed request the control plane accepted, kept
    # for as long as the request's timestamp would still be. In the
    # database, so a restart or a second node can't be told one twice.
    create table(:relay_nonces, primary_key: false) do
      add :nonce, :string, primary_key: true
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:relay_nonces, [:expires_at])

    # Not "public" or "service": no flow that issues a token accepts it.
    execute(
      "INSERT INTO oauth_clients (id, name, kind, inserted_at, updated_at) VALUES ('foreman-environment', 'Foreman environment', 'environment', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      "DELETE FROM oauth_clients WHERE id = 'foreman-environment'"
    )

    # Last here, so first on the way down, while the grants still exist.
    execute(fn -> :ok end, &forget_requests/0)
  end

  # An environment grant can be the one that asked for an environment's
  # desired state. Rolled back, the grants go and the release that reads
  # them is gone too, so those states are left as their owners' own:
  # otherwise nothing could repair them until someone asked again.
  #
  # An operation still waiting can hold the authority it replaced, to put
  # back if it's cancelled. Those go the same way.
  defp forget_requests do
    postgres? = repo().__adapter__() == Ecto.Adapters.Postgres
    grants = "SELECT CAST(id AS TEXT) FROM oauth_grants WHERE environment_id IS NOT NULL"

    {current, prior, without} =
      if postgres? do
        {"desired_authority->>'grant_id'", "args->'prior_authority'->>'grant_id'",
         "args - 'prior_authority'"}
      else
        {"json_extract(desired_authority, '$.grant_id')",
         "json_extract(args, '$.prior_authority.grant_id')",
         "json_remove(args, '$.prior_authority')"}
      end

    repo().query!(
      "UPDATE environments SET desired_authority = NULL WHERE #{current} IN (#{grants})"
    )

    repo().query!("UPDATE operations SET args = #{without} WHERE #{prior} IN (#{grants})")
  end
end
