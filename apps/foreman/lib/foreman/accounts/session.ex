defmodule Foreman.Accounts.Session do
  @moduledoc "A signed-in browser session. Only a hash of the token is stored."
  use Foreman.Schema

  schema "user_sessions" do
    belongs_to :user, Foreman.Accounts.User
    field :token_hash, :binary, redact: true
    field :user_agent, :string
    field :last_seen_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
