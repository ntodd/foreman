defmodule Foreman.OAuth.Device do
  @moduledoc false
  use Foreman.Schema

  schema "oauth_devices" do
    belongs_to :client, Foreman.OAuth.Client, type: :string
    field :device_hash, :binary, redact: true
    field :user_code_hash, :binary, redact: true
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime_usec
    field :poll_after, :utc_datetime_usec
    field :interval, :integer, default: 5
    field :state, :string, default: "pending"
    belongs_to :grant, Foreman.OAuth.Grant
  end
end
