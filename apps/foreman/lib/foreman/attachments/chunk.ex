defmodule Foreman.Attachments.Chunk do
  @moduledoc """
  One piece of an upload, at the byte it starts at.

  `data` is encrypted with the vault's key by `Foreman.Attachments`, not
  by the field's type. Every field of an encrypted type is read whole
  when the control plane boots with changed keys, and rewritten when
  they are rotated: right for secrets, and megabytes of someone's file
  that is gone in ten minutes has no place in either. A chunk the keys
  can no longer read is a lost one, and its file is sent again.
  """
  use Foreman.Schema

  schema "attachment_chunks" do
    belongs_to :upload, Foreman.Attachments.Upload
    field :position, :integer
    field :data, :binary, redact: true
  end
end
