defmodule Foreman.OAuth.Token do
  @moduledoc false
  use Foreman.Schema

  schema "oauth_tokens" do
    field :digest, :binary, redact: true
    field :kind, :string
    belongs_to :grant, Foreman.OAuth.Grant
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
  end
end
