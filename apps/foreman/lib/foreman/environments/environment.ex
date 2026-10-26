defmodule Foreman.Environments.Environment do
  @moduledoc """
  One running copy of a repo on a box.

  `desired_state` is what the user asked for (running, stopped,
  destroyed); `observed_state` is what the agent last reported. The
  environment server works to make them match.
  """
  use Foreman.Schema

  @desired ~w(running stopped destroyed)
  @observed ~w(pending creating starting stopping running stopped partial missing error destroying destroyed)

  schema "environments" do
    field :slug, :string
    field :index, :integer
    belongs_to :repo, Foreman.Repos.Repo
    belongs_to :user, Foreman.Accounts.User
    belongs_to :box, Foreman.Boxes.Box
    field :branch, :string
    field :desired_state, :string, default: "running"
    field :observed_state, :string, default: "pending"
    field :status_message, :string
    field :cpu_limit, :float
    field :memory_limit_mb, :integer
    field :applied_secret_hashes, :map
    field :pending_restart, :boolean, default: false
    field :pending_changes, {:array, :string}, default: []
    field :remote_user, :string
    field :workspace_folder, :string
    field :services, {:array, :string}, default: []
    field :devcontainer_service, :string
    field :warnings, {:array, :string}, default: []
    field :host_requirements, :map
    field :feature_version, :string
    # What `ForemanProtocol.Connect.cast_hooks/1` kept of the hooks the
    # agent reported when it last came up.
    field :connect_hooks, {:array, :map}, default: []
    field :tailscale_device_id, :string
    field :ts_authkey, Foreman.Encrypted.Binary, redact: true
    field :created_once, :boolean, default: false
    field :token_pushed_at, :utc_datetime_usec
    field :destroyed_at, :utc_datetime_usec
    # Set by `Environments.record_result/1` when an up applied secrets the
    # files on the box still say have changed.
    field :stale_notice, :boolean, virtual: true, default: false
    timestamps()
  end

  def desired_states, do: @desired
  def observed_states, do: @observed

  def create_changeset(env, attrs) do
    env
    |> cast(attrs, [
      :slug,
      :index,
      :repo_id,
      :user_id,
      :box_id,
      :branch,
      :cpu_limit,
      :memory_limit_mb
    ])
    |> validate_required([:slug, :index, :repo_id, :user_id, :box_id, :branch])
    |> validate_format(:slug, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
    |> validate_branch()
    |> validate_limits()
    # Postgres names the partial index; SQLite reports the columns instead.
    |> unique_constraint(:slug, name: :environments_live_slug_index)
    |> unique_constraint(:slug, name: :environments_slug_index)
  end

  def limits_changeset(env, attrs) do
    env
    |> cast(attrs, [:cpu_limit, :memory_limit_mb])
    |> validate_limits()
  end

  defp validate_limits(changeset) do
    changeset
    |> validate_number(:cpu_limit, greater_than: 0, less_than_or_equal_to: 512)
    |> validate_number(:memory_limit_mb, greater_than_or_equal_to: 256)
  end

  defp validate_branch(changeset) do
    validate_change(changeset, :branch, fn :branch, branch ->
      case ForemanProtocol.Schema.cast(%{"b" => branch}, b: {:git_ref, required: true}) do
        {:ok, _} -> []
        {:error, _} -> [branch: "isn't a valid branch name"]
      end
    end)
  end

  def state_changeset(env, attrs) do
    env
    |> cast(attrs, [
      :desired_state,
      :observed_state,
      :status_message,
      :applied_secret_hashes,
      :pending_restart,
      :pending_changes,
      :remote_user,
      :workspace_folder,
      :services,
      :devcontainer_service,
      :warnings,
      :host_requirements,
      :feature_version,
      :connect_hooks,
      :tailscale_device_id,
      :ts_authkey,
      :created_once,
      :token_pushed_at,
      :destroyed_at
    ])
    |> validate_inclusion(:desired_state, @desired)
    |> validate_inclusion(:observed_state, @observed)
  end

  def live?(%__MODULE__{destroyed_at: nil}), do: true
  def live?(_), do: false
end
