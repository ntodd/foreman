defmodule Foreman.Boxes.Box do
  @moduledoc """
  A machine running the Foreman agent. A box belongs to one user and only
  runs that user's environments unless shared with others.
  """
  use Foreman.Schema

  @policies ~w(allow warn refuse)

  schema "boxes" do
    field :name, :string
    belongs_to :owner_user, Foreman.Accounts.User
    field :shared_user_ids, {:array, :string}, default: []
    field :public_key, :binary, redact: true
    field :agent_version, :string
    field :protocol_version, :integer
    field :feature_version, :string
    field :desired_agent_version, :string
    field :failed_agent_version, :string
    field :hostname, :string
    field :os, :string
    field :arch, :string
    field :capacity, :map
    field :capacity_policy, :string, default: "allow"
    field :contention_threshold, :float, default: 0.9
    field :policy, :map
    field :last_seen_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def policies, do: @policies

  def settings_changeset(box, attrs) do
    box
    |> cast(attrs, [
      :name,
      :capacity_policy,
      :contention_threshold,
      :desired_agent_version,
      :owner_user_id,
      :shared_user_ids
    ])
    |> validate_required([:name])
    |> validate_name()
    |> validate_inclusion(:capacity_policy, @policies)
    |> validate_number(:contention_threshold, greater_than: 0, less_than_or_equal_to: 4)
    |> validate_format(:desired_agent_version, ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?\z/)
    |> unique_constraint(:name)
  end

  def validate_name(changeset) do
    changeset
    |> validate_format(:name, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/,
      message: "must be lowercase letters, digits and dashes"
    )
  end

  def usable_by?(%__MODULE__{revoked_at: revoked}, _user) when not is_nil(revoked), do: false
  def usable_by?(%__MODULE__{}, %{role: "admin"}), do: true
  def usable_by?(%__MODULE__{owner_user_id: id}, %{id: id}), do: true
  def usable_by?(%__MODULE__{shared_user_ids: ids}, %{id: id}), do: id in ids
end
