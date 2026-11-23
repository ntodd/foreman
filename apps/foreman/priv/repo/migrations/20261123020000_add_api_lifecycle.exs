defmodule Foreman.Repo.Migrations.AddApiLifecycle do
  use Ecto.Migration

  def change do
    alter table(:environments) do
      add :api_grant_id, :binary_id
      add :expiry_at, :utc_datetime_usec
      add :expiry_action, :string
      add :expiry_consumed_at, :utc_datetime_usec
    end

    alter table(:operations) do
      add :api_grant_id, :binary_id
      add :trigger, :string, null: false, default: "request"
    end

    # The original identifiers must outlive operation history. A unique key
    # serializes competing submissions before either can reserve capacity.
    create table(:api_mutation_receipts, primary_key: false) do
      add :key_hash, :binary, primary_key: true
      add :input, :map, null: false
      add :environment_id, :binary_id
      add :operation_id, :binary_id
    end
  end
end
