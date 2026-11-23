defmodule Foreman.PublicAPI.Receipt do
  @moduledoc "The accepted result for an actor, client, endpoint and idempotency key."
  use Ecto.Schema

  @primary_key {:key_hash, :binary, autogenerate: false}
  schema "api_mutation_receipts" do
    field :input, :map
    field :environment_id, :binary_id
    field :operation_id, :binary_id
  end
end
