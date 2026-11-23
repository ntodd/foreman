defmodule Foreman.Repo.Migrations.CreateOAuth do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :service_account, :boolean, null: false, default: false
    end

    create table(:oauth_clients, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false
      add :secret_hash, :binary
      add :disabled_at, :utc_datetime_usec
      timestamps()
    end

    execute(
      "INSERT INTO oauth_clients (id, name, kind, inserted_at, updated_at) VALUES ('foreman-cli', 'Foreman CLI', 'public', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
      "DELETE FROM oauth_clients WHERE id = 'foreman-cli'"
    )

    create table(:oauth_grants) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :client_id, references(:oauth_clients, type: :string, on_delete: :delete_all),
        null: false

      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :repo_ids, {:array, :string}, null: false, default: []
      add :box_ids, {:array, :string}, null: false, default: []
      add :secret_ids, {:array, :string}, null: false, default: []
      add :network_policy, :map
      timestamps()
    end

    create index(:oauth_grants, [:user_id, :revoked_at])
    create index(:oauth_grants, [:client_id])

    create table(:oauth_devices) do
      add :client_id, references(:oauth_clients, type: :string, on_delete: :delete_all),
        null: false

      add :device_hash, :binary, null: false
      add :user_code_hash, :binary, null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :poll_after, :utc_datetime_usec
      add :interval, :integer, null: false
      add :state, :string, null: false
      add :grant_id, references(:oauth_grants, on_delete: :delete_all)
    end

    create unique_index(:oauth_devices, [:device_hash])
    create unique_index(:oauth_devices, [:user_code_hash])
    create index(:oauth_devices, [:expires_at])

    create table(:oauth_tokens) do
      add :digest, :binary, null: false
      add :kind, :string, null: false
      add :grant_id, references(:oauth_grants, on_delete: :delete_all), null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
    end

    create unique_index(:oauth_tokens, [:digest])
    create index(:oauth_tokens, [:grant_id])
    create index(:oauth_tokens, [:expires_at])
  end
end
