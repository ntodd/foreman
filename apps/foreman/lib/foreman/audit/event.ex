defmodule Foreman.Audit.Event do
  @moduledoc false
  use Foreman.Schema

  schema "audit_events" do
    belongs_to :actor, Foreman.Accounts.User
    field :actor_login, :string
    field :action, :string
    field :subject_type, :string
    field :subject_id, :string
    field :metadata, :map
    timestamps(updated_at: false)
  end
end
