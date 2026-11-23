defmodule Foreman.OAuth.Client do
  @moduledoc false
  use Foreman.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "oauth_clients" do
    field :name, :string
    field :kind, :string
    field :secret_hash, :binary, redact: true
    field :disabled_at, :utc_datetime_usec
    timestamps()
  end
end
