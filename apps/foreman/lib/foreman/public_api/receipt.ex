defmodule Foreman.PublicAPI.Receipt do
  @moduledoc "The accepted result for an actor, client, endpoint and idempotency key."
  use Ecto.Schema
  import Ecto.Query
  alias Foreman.Repo

  @primary_key {:key_hash, :binary, autogenerate: false}
  schema "api_mutation_receipts" do
    field :input, :map
    field :environment_id, :binary_id
    field :operation_id, :binary_id
  end

  def key_hash(actor, endpoint, key) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({actor.kind, actor.user.id, actor.client_id, endpoint, key},
        minor_version: 1
      )
    )
  end

  def reserve(hash, input, accept) do
    Repo.transact(fn ->
      case Repo.insert_all(__MODULE__, [%{key_hash: hash, input: input}],
             on_conflict: :nothing,
             conflict_target: [:key_hash]
           ) do
        {0, _} ->
          {:ok, {:replay, Repo.get!(__MODULE__, hash)}}

        {1, _} ->
          case accept.() do
            {:accept, env_id, op_id} ->
              {1, _} =
                Repo.update_all(from(r in __MODULE__, where: r.key_hash == ^hash),
                  set: [environment_id: env_id, operation_id: op_id]
                )

              {:ok, {:accepted, env_id, op_id}}

            error ->
              {:error, error}
          end
      end
    end)
  end
end
