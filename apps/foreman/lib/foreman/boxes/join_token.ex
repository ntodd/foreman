defmodule Foreman.Boxes.JoinToken do
  @moduledoc "A single-use, short-lived token an agent enrolls with. Stored hashed."
  use Foreman.Schema

  schema "join_tokens" do
    field :token_hash, :binary, redact: true
    field :box_name, :string
    belongs_to :owner_user, Foreman.Accounts.User
    belongs_to :created_by, Foreman.Accounts.User
    belongs_to :box, Foreman.Boxes.Box
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
