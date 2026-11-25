defmodule Foreman.Repo.Migrations.AddAttachmentUploads do
  use Ecto.Migration

  def change do
    # A machine user's fine-grained token, which the control plane alone
    # uses to upload an environment's images to its repository's
    # attachments. It never goes to a box.
    alter table(:owners) do
      add :attachment_token, :binary
      add :attachment_login, :string
      add :attachment_token_expires_at, :utc_datetime_usec
      add :attachment_checked_at, :utc_datetime_usec
    end

    # A file on its way from an environment to GitHub. A box relays at
    # most 900 kB a request, so it arrives in chunks and is held here for
    # the minutes that takes, then deleted.
    create table(:attachment_uploads, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :environment_id, references(:environments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repository_id, :bigint, null: false
      add :name, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false
      add :received, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:attachment_uploads, [:environment_id])
    create index(:attachment_uploads, [:updated_at])

    # One key column, like every table with an encrypted one: the key
    # rotation task (`Foreman.Release.reencrypt/0`) finds rows by it.
    create table(:attachment_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :upload_id,
          references(:attachment_uploads, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :bigint, null: false
      add :data, :binary, null: false
    end

    create unique_index(:attachment_chunks, [:upload_id, :position])
  end
end
