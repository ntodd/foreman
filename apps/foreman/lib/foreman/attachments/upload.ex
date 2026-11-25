defmodule Foreman.Attachments.Upload do
  @moduledoc """
  A file an environment is sending to its repository's attachments, while
  its chunks arrive. Deleted once GitHub has it, or when nothing has been
  sent to it for a while.
  """
  use Foreman.Schema

  schema "attachment_uploads" do
    belongs_to :environment, Foreman.Environments.Environment
    # The repository's id on GitHub, which is what the upload names.
    field :repository_id, :integer
    field :name, :string
    field :content_type, :string
    field :size, :integer
    field :received, :integer, default: 0
    timestamps()
  end
end
