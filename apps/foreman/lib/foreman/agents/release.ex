defmodule Foreman.Agents.Release do
  @moduledoc "A signed agent release tarball the control plane serves to boxes."
  use Foreman.Schema

  schema "agent_releases" do
    field :version, :string
    field :target, :string
    field :sha256, :string
    field :signature, :string
    field :size, :integer
    field :path, :string
    timestamps(updated_at: false)
  end
end
