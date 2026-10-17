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
    # Where it last came up ("container" or "vm") and, in a VM, the VM's
    # name, cpus and memory_mb. Null until it has come up.
    field :isolation, :string
    field :vm, :map
    field :tailscale_device_id, :string
    field :ts_authkey, Foreman.Encrypted.Binary, redact: true
    field :created_once, :boolean, default: false
    field :token_pushed_at, :utc_datetime_usec
    field :destroyed_at, :utc_datetime_usec
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
      :isolation,
      :vm,
      :tailscale_device_id,
      :ts_authkey,
      :created_once,
      :token_pushed_at,
      :destroyed_at
    ])
    |> validate_inclusion(:desired_state, @desired)
    |> validate_inclusion(:observed_state, @observed)
    |> validate_inclusion(:isolation, ~w(container vm))
  end

  def live?(%__MODULE__{destroyed_at: nil}), do: true
  def live?(_), do: false

  @doc """
  The isolation it was made under: what its last create, rebuild or
  start reported, else containers for one that came up before that was
  recorded, else nil (it hasn't come up yet).
  """
  def made_under(%__MODULE__{isolation: isolation}) when isolation in ["container", "vm"],
    do: isolation

  def made_under(%__MODULE__{created_once: true}), do: "container"
  def made_under(_env), do: nil

  @doc """
  Whether its box (`env.box`) now runs environments the other way from
  how this one was made. A box finds containers through Docker and VMs
  through Incus, so it can't see this one at all.
  """
  def isolation_changed?(%__MODULE__{box: %Foreman.Boxes.Box{isolation: isolation}} = env) do
    made = made_under(env)
    made != nil and made != isolation
  end

  def isolation_changed?(_env), do: false
end
