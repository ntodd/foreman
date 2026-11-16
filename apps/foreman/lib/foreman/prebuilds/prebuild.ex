defmodule Foreman.Prebuilds.Prebuild do
  @moduledoc """
  A repo's environment disk that a box built once (the clone, its
  devcontainer's images), for one branch and devcontainer config. Its id
  is the one the box keeps it under. `building`, then `ready` or `failed`.
  """
  use Foreman.Schema

  @statuses ~w(building ready failed)

  schema "prebuilds" do
    belongs_to :repo, Foreman.Repos.Repo
    belongs_to :box, Foreman.Boxes.Box
    field :branch, :string
    field :config_path, :string
    field :status, :string, default: "building"
    field :error, :string
    field :size_mb, :integer
    field :op_id, :binary_id
    field :built_at, :utc_datetime_usec
    timestamps()
  end

  def statuses, do: @statuses
end
