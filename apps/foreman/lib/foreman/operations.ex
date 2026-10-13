defmodule Foreman.Operations do
  @moduledoc """
  Commands sent to agents and their outcomes. An operation's id is the
  command's op_id. Logs stream to subscribers as they arrive and are
  flushed to the database in batches (`Foreman.Operations.LogBuffer`).
  """
  import Ecto.Query

  alias Foreman.Operations.{LogBuffer, Operation, Redactions}
  alias Foreman.Repo

  @active ~w(queued dispatched running)

  def get(id), do: Repo.get(Operation, id)
  def get!(id), do: Repo.get!(Operation, id)

  def create!(attrs), do: Repo.insert!(struct(Operation, attrs))

  def list_for_environment(env_id, limit \\ 20) do
    from(o in Operation,
      where: o.environment_id == ^env_id,
      order_by: [desc: o.inserted_at],
      limit: ^limit,
      preload: :user
    )
    |> Repo.all()
  end

  def list_for_box(box_id, limit \\ 20) do
    from(o in Operation,
      where: o.box_id == ^box_id,
      order_by: [desc: o.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "The environment's operation that's been sent but hasn't finished, if any."
  def in_flight(env_id) do
    from(o in Operation,
      where: o.environment_id == ^env_id and o.status in ["dispatched", "running"],
      order_by: o.inserted_at,
      limit: 1
    )
    |> Repo.one()
  end

  def next_queued(env_id) do
    from(o in Operation,
      where: o.environment_id == ^env_id and o.status == "queued",
      order_by: o.inserted_at,
      limit: 1
    )
    |> Repo.one()
  end

  def active?(env_id) do
    Repo.exists?(from o in Operation, where: o.environment_id == ^env_id and o.status in ^@active)
  end

  def active_for_box(box_id) do
    from(o in Operation,
      where: o.box_id == ^box_id and o.status in ["dispatched", "running"],
      order_by: o.inserted_at
    )
    |> Repo.all()
  end

  def environments_with_queued(box_id) do
    from(o in Operation,
      where: o.box_id == ^box_id and o.status == "queued" and not is_nil(o.environment_id),
      distinct: true,
      select: o.environment_id
    )
    |> Repo.all()
  end

  def mark(%Operation{} = op, status, extra \\ []) do
    op |> Ecto.Changeset.change([status: status] ++ extra) |> Repo.update!() |> tap(&broadcast/1)
  end

  def mark_running(op_id) do
    case get(op_id) do
      %Operation{status: "dispatched"} = op -> mark(op, "running", started_at: DateTime.utc_now())
      other -> other
    end
  end

  @doc "Records the outcome. Returns `{:ok, op}` the first time, `:already` for a repeat."
  def finish(op_id, status, result, error) do
    case get(op_id) do
      %Operation{} = op ->
        if Operation.finished?(op) do
          :already
        else
          LogBuffer.flush(op_id)
          error = error && Redactions.redact(op_id, error)
          Redactions.delete(op_id)

          {:ok,
           mark(get!(op_id), if(status == "ok", do: "succeeded", else: "failed"),
             result: result,
             error: error,
             finished_at: DateTime.utc_now()
           )}
        end

      nil ->
        :unknown
    end
  end

  def cancel_queued(%Operation{status: "queued"} = op),
    do: mark(op, "cancelled", finished_at: DateTime.utc_now())

  def append_log(op_id, data), do: LogBuffer.append(op_id, data)

  @doc "The operation's full log, including anything not flushed yet."
  def log(%Operation{} = op), do: (op.log || "") <> LogBuffer.pending(op.id)

  def subscribe(op_id), do: Phoenix.PubSub.subscribe(Foreman.PubSub, "operation:" <> op_id)

  defp broadcast(%Operation{} = op) do
    Phoenix.PubSub.broadcast(Foreman.PubSub, "operation:" <> op.id, {:operation, op})

    if op.environment_id,
      do:
        Phoenix.PubSub.broadcast(
          Foreman.PubSub,
          "environment:" <> op.environment_id,
          {:operation, op}
        )
  end
end
