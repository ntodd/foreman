defmodule Foreman.OAuth.Grant do
  @moduledoc false
  use Foreman.Schema

  schema "oauth_grants" do
    belongs_to :user, Foreman.Accounts.User
    belongs_to :client, Foreman.OAuth.Client, type: :string
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :repo_ids, {:array, :string}, default: []
    field :box_ids, {:array, :string}, default: []
    field :secret_ids, {:array, :string}, default: []
    field :network_policy, :map
    timestamps()
  end
end
