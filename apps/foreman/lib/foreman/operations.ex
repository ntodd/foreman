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

  @doc "The environment's newest operations; `except:` leaves out the actions it names."
  def list_for_environment(env_id, limit \\ 20, opts \\ []) do
    except = Keyword.get(opts, :except, [])

    from(o in Operation,
      where: o.environment_id == ^env_id and o.action not in ^except,
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

  @doc """
  The environment's next operation to send: a queued secrets write first
  (a secret changed after a restart was queued, say, and the restart
  should see it), then the oldest.
  """
  def next_queued(env_id) do
    from(o in Operation,
      where: o.environment_id == ^env_id and o.status == "queued",
      order_by: [
        asc: fragment("CASE WHEN ? = 'secrets_write' THEN 0 ELSE 1 END", o.action),
        asc: o.inserted_at
      ],
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

  @doc """
  Restarts Housekeeping's clock for operations about to be resent after an
  outage: an agent that restarted runs them from the start.
  """
  def restart_clock([]), do: :ok

  def restart_clock(ids) do
    Repo.update_all(
      from(o in Operation, where: o.id in ^ids and o.status in ["dispatched", "running"]),
      set: [dispatched_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  Records that someone asked to stop the operation. The `op.cancel` can be
  lost with the connection, so a resend sends it again rather than the
  operation. `withdraw_cancel/1` takes it back when the cancel couldn't be
  sent at all.
  """
  def request_cancel(%Operation{id: id}), do: set_cancel_requested(id, DateTime.utc_now())
  def withdraw_cancel(%Operation{id: id}), do: set_cancel_requested(id, nil)

  defp set_cancel_requested(id, at) do
    Repo.update_all(from(o in Operation, where: o.id == ^id), set: [cancel_requested_at: at])
    :ok
  end

  def cancel_requested?(%Operation{cancel_requested_at: at}), do: not is_nil(at)

  def environments_with_queued(box_id) do
    from(o in Operation,
      where: o.box_id == ^box_id and o.status == "queued" and not is_nil(o.environment_id),
      distinct: true,
      select: o.environment_id
    )
    |> Repo.all()
  end

  def mark(%Operation{} = op, status, extra \\ []) do
    op = op |> Ecto.Changeset.change([status: status] ++ extra) |> Repo.update!()
    if Operation.finished?(op), do: Redactions.delete(op.id)
    tap(op, &broadcast/1)
  end

  def mark_running(op_id) do
    case get(op_id) do
      %Operation{status: "dispatched"} = op -> mark(op, "running", started_at: DateTime.utc_now())
      other -> other
    end
  end

  @doc """
  Records the outcome. Returns `{:ok, op}` the first time, `:already` for
  a repeat and `:unknown` for an operation that doesn't exist.

  A result for an operation Housekeeping gave up on is still taken: the
  agent did the work, so its outcome is the true one.
  """
  def finish(op_id, status, result, error) do
    case finish(op_id, status, result, error, fn _op -> nil end) do
      {:ok, op, _} -> {:ok, op}
      other -> other
    end
  end

  @doc """
  Like `finish/4`, with `apply` run in the same transaction as the
  update, given the finished operation, so its effects (the environment's
  new state) are recorded together with it or not at all. Returns
  `{:ok, op, applied}`, `applied` being what `apply` returned.
  """
  def finish(op_id, status, result, error, apply) do
    case get(op_id) do
      # Housekeeping cancels what it gives up on, so "cancelled" for a timed
      # out operation is its own cancel coming back: the timeout stays, and
      # isn't taken for someone cancelling a stop to keep it running.
      %Operation{} = op ->
        if (Operation.finished?(op) and not timed_out?(op)) or
             (timed_out?(op) and error == "cancelled"),
           do: :already,
           else: do_finish(op_id, status, result, error, apply)

      nil ->
        :unknown
    end
  end

  defp do_finish(op_id, status, result, error, apply) do
    # Before the transaction: the buffer writes from its own process, which
    # on SQLite would wait on this transaction's write lock.
    LogBuffer.flush(op_id)
    error = error && Redactions.redact(op_id, error)

    {:ok, {op, applied}} =
      Repo.transact(fn ->
        op = get!(op_id)

        op =
          op
          |> Ecto.Changeset.change(outcome(op, status, result, error))
          |> Repo.update!()

        {:ok, {op, apply.(op)}}
      end)

    Redactions.delete(op_id)
    broadcast(op)
    Foreman.Activity.operation_finished(op)
    {:ok, op, applied}
  end

  @doc "Whether Housekeeping failed the operation for taking too long (see `timed_out/2`)."
  def timed_out?(%Operation{status: "failed", args: %{"timed_out" => true}}), do: true
  def timed_out?(%Operation{}), do: false

  @doc """
  Fails an operation that never reported back. A late result still
  replaces this. `:finished` if a result landed since `op` was read: the
  check and the update are one statement, so this never overwrites it.
  """
  def timed_out(%Operation{} = op, error) do
    case timed_out(op, error, fn _op -> nil end) do
      {:ok, op, _} -> {:ok, op}
      :finished -> :finished
    end
  end

  @doc """
  Like `timed_out/2`, with `apply` run in the same transaction, given the
  failed operation, so a real result can't land between the failure and
  its effect on the environment. Returns `{:ok, op, applied}` or
  `:finished`.

  `dispatched_before:` only fails it if it was still dispatched before
  then, checked in the same statement: Housekeeping works from a list read
  earlier, and a reconnect may have restarted the clock since.
  """
  def timed_out(%Operation{id: id} = op, error, apply, opts \\ []) do
    now = DateTime.utc_now()

    query =
      from(o in Operation, where: o.id == ^id and o.status in ["queued", "dispatched", "running"])

    query =
      case opts[:dispatched_before] do
        nil -> query
        cutoff -> from(o in query, where: o.dispatched_at < ^cutoff)
      end

    {:ok, outcome} =
      Repo.transact(fn ->
        {count, _} =
          query
          |> Repo.update_all(
            set: [
              status: "failed",
              error: error,
              args: Map.put(op.args || %{}, "timed_out", true),
              finished_at: now,
              updated_at: now
            ]
          )

        if count == 1 do
          op = get!(id)
          {:ok, {op, apply.(op)}}
        else
          {:ok, :finished}
        end
      end)

    case outcome do
      {op, applied} ->
        Redactions.delete(id)
        broadcast(op)
        Foreman.Activity.operation_finished(op)
        {:ok, op, applied}

      :finished ->
        :finished
    end
  end

  # An agent that has put a new release in place reports it before it
  # restarts into it (once it's idle), so the update isn't done until the
  # agent comes back on the new version (`Foreman.Agents.Releases`). A real
  # result also clears Housekeeping's timeout.
  defp outcome(%Operation{action: "agent.update"} = op, "ok", %{"restart" => true} = result, nil) do
    args = Map.delete(op.args || %{}, "timed_out")

    [
      status: "running",
      result: result,
      error: nil,
      finished_at: nil,
      args: Map.put_new(args, "restart_reported_at", DateTime.to_iso8601(DateTime.utc_now()))
    ]
  end

  defp outcome(op, status, result, error) do
    [
      status: finished_status(status, error),
      result: result,
      error: error,
      args: Map.delete(op.args || %{}, "timed_out"),
      finished_at: DateTime.utc_now()
    ]
  end

  # The agent reports an operation it killed for `op.cancel` as the error
  # "cancelled" (ForemanAgent.Ops).
  defp finished_status("ok", _error), do: "succeeded"
  defp finished_status(_status, "cancelled"), do: "cancelled"
  defp finished_status(_status, _error), do: "failed"

  @doc """
  Cancels a queued operation. `{:error, :not_queued}` if it has left the
  queue since `op` was read (it was sent, say): the check and the update
  are one statement, so a cancel can't overwrite a dispatch.
  """
  def cancel_queued(%Operation{} = op) do
    case transition(op, "queued", status: "cancelled", finished_at: DateTime.utc_now()) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, :not_queued}
    end
  end

  @doc "Fails a queued operation that couldn't be sent. `:error` if it isn't queued any more."
  def fail_queued(%Operation{} = op, error),
    do: transition(op, "queued", status: "failed", error: error, finished_at: DateTime.utc_now())

  @doc "Takes a queued operation for sending. `:error` if it isn't queued any more."
  def claim(%Operation{} = op, fields),
    do: transition(op, "queued", [status: "dispatched"] ++ fields)

  defp transition(op, from, fields) do
    query = from(o in Operation, where: o.id == ^op.id and o.status == ^from)

    case Repo.update_all(query, set: fields) do
      {1, _} -> {:ok, op.id |> get!() |> tap(&broadcast/1)}
      {0, _} -> :error
    end
  end

  @doc "Clears the logs of operations that finished before `cutoff`. Returns how many."
  def prune_logs(cutoff) do
    {count, _} =
      Repo.update_all(
        from(o in Operation, where: o.finished_at < ^cutoff and not is_nil(o.log)),
        set: [log: nil]
      )

    count
  end

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
