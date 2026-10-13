defmodule Foreman.Repo.Migrations.CreateCoreTables do
  # Portable across SQLite and Postgres: Ecto's DSL only, binary ids,
  # JSON in :map columns, and partial indexes (which both support).
  use Ecto.Migration

  def change do
    create table(:users) do
      add :github_id, :bigint
      add :login, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :role, :string, null: false, default: "member"
      add :access_token, :binary
      add :access_token_expires_at, :utc_datetime_usec
      add :refresh_token, :binary
      add :refresh_token_expires_at, :utc_datetime_usec
      add :github_login_expired, :boolean, null: false, default: false
      add :git_name, :string
      add :git_email, :string
      add :dotfiles_repository, :string
      add :dotfiles_install_command, :string
      add :disabled_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:users, [:login])
    create unique_index(:users, [:github_id])

    create table(:user_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :user_agent, :string
      add :last_seen_at, :utc_datetime_usec
      timestamps(updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_id])

    create table(:owners) do
      add :login, :string, null: false
      add :kind, :string, null: false, default: "User"
      add :github_id, :bigint
      add :installation_id, :bigint
      add :registry_host, :string
      add :registry_username, :string
      add :registry_token, :binary
      add :registry_token_expires_at, :utc_datetime_usec
      add :registry_scopes, :string
      add :registry_checked_at, :utc_datetime_usec
      add :registry_error, :text
      timestamps()
    end

    create unique_index(:owners, [:login])

    create table(:repos) do
      add :owner_id, references(:owners, on_delete: :delete_all), null: false
      add :full_name, :string, null: false
      add :name, :string, null: false
      add :github_id, :bigint
      add :default_branch, :string, null: false, default: "main"
      add :private, :boolean, null: false, default: true
      add :archived, :boolean, null: false, default: false
      add :manual, :boolean, null: false, default: false
      add :devcontainer_path, :string
      add :devcontainer_checked_at, :utc_datetime_usec
      add :devcontainer_error, :text
      add :host_requirements, :map
      add :private_registry_refs, {:array, :string}, null: false, default: []
      add :token_mode, :string, null: false, default: "scoped"
      add :extra_repos, {:array, :string}, null: false, default: []
      add :token_permissions, :map
      add :tailscale_tags, {:array, :string}, null: false, default: []
      add :cpu_limit, :float
      add :memory_limit_mb, :integer
      timestamps()
    end

    create unique_index(:repos, [:full_name])
    create index(:repos, [:owner_id])

    create table(:user_repo_settings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :repo_id, references(:repos, on_delete: :delete_all), null: false
      add :git_name, :string
      add :git_email, :string
      add :dotfiles_repository, :string
      add :dotfiles_install_command, :string
      timestamps()
    end

    create unique_index(:user_repo_settings, [:user_id, :repo_id])

    create table(:boxes) do
      add :name, :string, null: false
      add :owner_user_id, references(:users, on_delete: :nilify_all)
      add :shared_user_ids, {:array, :string}, null: false, default: []
      add :public_key, :binary
      add :agent_version, :string
      add :protocol_version, :integer
      add :desired_agent_version, :string
      add :hostname, :string
      add :os, :string
      add :arch, :string
      add :capacity, :map
      add :capacity_policy, :string, null: false, default: "allow"
      add :contention_threshold, :float, null: false, default: 0.9
      add :last_seen_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps()
    end

    create unique_index(:boxes, [:name])

    create table(:join_tokens) do
      add :token_hash, :binary, null: false
      add :box_name, :string, null: false
      add :owner_user_id, references(:users, on_delete: :delete_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :box_id, references(:boxes, on_delete: :nilify_all)
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      timestamps(updated_at: false)
    end

    create unique_index(:join_tokens, [:token_hash])

    create table(:environments) do
      add :slug, :string, null: false
      add :index, :integer, null: false
      add :repo_id, references(:repos, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :box_id, references(:boxes, on_delete: :restrict), null: false
      add :branch, :string, null: false
      add :desired_state, :string, null: false, default: "running"
      add :observed_state, :string, null: false, default: "pending"
      add :status_message, :text
      add :cpu_limit, :float
      add :memory_limit_mb, :integer
      add :applied_secret_hashes, :map
      add :pending_restart, :boolean, null: false, default: false
      add :pending_changes, {:array, :string}, null: false, default: []
      add :remote_user, :string
      add :workspace_folder, :string
      add :services, {:array, :string}, null: false, default: []
      add :devcontainer_service, :string
      add :warnings, {:array, :string}, null: false, default: []
      add :host_requirements, :map
      add :tailscale_device_id, :string
      add :ts_authkey, :binary
      add :created_once, :boolean, null: false, default: false
      add :token_pushed_at, :utc_datetime_usec
      add :destroyed_at, :utc_datetime_usec
      timestamps()
    end

    # A destroyed environment's slug can be reused.
    create unique_index(:environments, [:slug],
             where: "destroyed_at IS NULL",
             name: :environments_live_slug_index
           )

    create index(:environments, [:box_id])
    create index(:environments, [:user_id])
    create index(:environments, [:repo_id])

    create table(:secrets) do
      add :scope, :string, null: false
      add :scope_key, :string, null: false
      add :owner_id, references(:owners, on_delete: :delete_all)
      add :repo_id, references(:repos, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :environment_id, references(:environments, on_delete: :delete_all)
      add :name, :string, null: false
      add :value, :binary, null: false
      add :repo_ids, {:array, :string}, null: false, default: []
      add :updated_by_id, references(:users, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:secrets, [:scope_key, :name])

    create table(:operations) do
      add :environment_id, references(:environments, on_delete: :delete_all)
      add :box_id, references(:boxes, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :command, :string, null: false
      add :args, :map
      add :status, :string, null: false, default: "queued"
      add :error, :text
      add :result, :map
      add :log, :text
      add :log_truncated, :boolean, null: false, default: false
      add :dispatched_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps()
    end

    create index(:operations, [:environment_id, :inserted_at])
    create index(:operations, [:box_id, :status])

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :binary, null: false
      timestamps()
    end

    create table(:agent_releases) do
      add :version, :string, null: false
      add :target, :string, null: false
      add :sha256, :string, null: false
      add :signature, :string, null: false
      add :size, :bigint, null: false
      add :path, :string, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:agent_releases, [:version, :target])

    create table(:audit_events) do
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :actor_login, :string
      add :action, :string, null: false
      add :subject_type, :string
      add :subject_id, :string
      add :metadata, :map
      timestamps(updated_at: false)
    end

    create index(:audit_events, [:inserted_at])
  end
end
