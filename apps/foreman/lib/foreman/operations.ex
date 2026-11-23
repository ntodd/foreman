defmodule Foreman.Operations do
  @moduledoc """
  Commands sent to agents and their outcomes. An operation's id is the
  command's op_id. Logs stream to subscribers as they arrive and are
  flushed to the database in batches (`Foreman.Operations.LogBuffer`).
  """
  import Ecto.Query

  alias Foreman.Operations.{LogBuffer, LogStore, Operation, Redactions, Retention}
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

  @doc "Recent box-level operations, with just the fields the box page displays."
  def recent_box_operations(box_id, limit) do
    from(o in Operation,
      where: o.box_id == ^box_id and is_nil(o.environment_id),
      order_by: [desc: o.inserted_at],
      limit: ^limit,
      select: map(o, [:action, :status, :error])
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
  def next_queued(env_id, created_once) do
    from(o in Operation,
      where: o.environment_id == ^env_id and o.status == "queued",
      where: ^created_once or is_nil(o.args["after_first_create"]),
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
    now = DateTime.utc_now()

    query =
      from o in Operation,
        where: o.id == ^op_id and o.status == "dispatched" and is_nil(o.finished_at),
        select: o

    case Repo.update_all(query, set: [status: "running", started_at: now, updated_at: now]) do
      {1, [op]} -> tap(op, &broadcast/1)
      {0, _} -> get(op_id)
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
        if already_finished?(op, error),
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

    {status, result, error} = checked_result(status, result, error)

    error = error && Redactions.redact(op_id, error)

    {:ok, finished} =
      Repo.transact(fn ->
        query = from o in Operation, where: o.id == ^op_id
        op = Repo.one!(if Repo.sqlite?(), do: query, else: lock(query, "FOR UPDATE"))

        if already_finished?(op, error) do
          {:ok, :already}
        else
          changes = outcome(op, status, result, error)
          updated = op |> Ecto.Changeset.change(changes) |> Repo.update!()
          applied = unless superseded_timeout?(op), do: apply.(updated)
          {:ok, {updated, applied}}
        end
      end)

    case finished do
      :already ->
        :already

      {op, applied} ->
        Redactions.delete(op_id)
        broadcast(op)
        Foreman.Activity.operation_finished(op)
        {:ok, op, applied}
    end
  end

  defp already_finished?(op, error) do
    if timed_out?(op), do: error == "cancelled", else: Operation.finished?(op)
  end

  # The late result corrects its own history. Once a later lifecycle command
  # was dispatched, it owns the environment state. Also serialize competing
  # results on the environment row so neither can race the visibility check.
  defp superseded_timeout?(%Operation{environment_id: nil}), do: false

  defp superseded_timeout?(op) do
    query =
      from e in Foreman.Environments.Environment,
        where: e.id == ^op.environment_id,
        select: e.destroyed_at

    destroyed_at = Repo.one!(if Repo.sqlite?(), do: query, else: lock(query, "FOR UPDATE"))

    timed_out?(op) and
      (not is_nil(destroyed_at) or
         Repo.exists?(
           from newer in Operation,
             where:
               newer.environment_id == ^op.environment_id and newer.id != ^op.id and
                 newer.dispatched_at >= ^op.finished_at,
             where:
               newer.action in ~w(create rebuild pull_rebuild start stop restart_all restart_affected suspend destroy)
         ))
  end

  @max_result_bytes 64 * 1024
  @result_fields ~w(branch changed_files unpushed_commits clean has_stash head base ahead
                    container_id resumed suspended vm_size remote_user remote_workspace_folder services
                    devcontainer_service warnings host_requirements feature_version tailscale_node_id
                    connect pull_failed size_mb rebooted restart version)

  defp checked_result(status, result, error) do
    cond do
      Foreman.DatabaseText.contains_nul?(result) ->
        {"error", %{}, error || "Operation result contains a NUL character"}

      is_map(result) and result_size(result) > @max_result_bytes ->
        fields = Map.take(result, @result_fields)

        if result_size(fields) <= @max_result_bytes,
          do: {status, fields, error},
          else: {"error", %{}, error || "Operation result exceeds 64 KiB"}

      true ->
        {status, result, error}
    end
  end

  defp result_size(result), do: result |> JSON.encode_to_iodata!() |> IO.iodata_length()

  @doc "Whether Housekeeping failed the operation for taking too long (see `timed_out/2`)."
  def timed_out?(%Operation{finished_at: %DateTime{}, args: %{"timed_out" => true}}), do: true
  def timed_out?(%Operation{}), do: false

  @doc """
  Fails an operation that never reported back. A late result still
  reconciles the physical outcome. Returns `:finished` if a timeout or
  result was already recorded, even if an older release reopened the row.
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
  then. The transaction locks the current row before applying the timeout
  because a reconnect may have restarted the clock since Housekeeping read it.
  """
  def timed_out(%Operation{id: id}, error, apply, opts \\ []) do
    query =
      from(o in Operation, where: o.id == ^id and o.status in ["queued", "dispatched", "running"])

    query =
      case opts[:dispatched_before] do
        nil -> query
        cutoff -> from(o in query, where: o.dispatched_at < ^cutoff)
      end

    {:ok, outcome} =
      Repo.transact(fn ->
        case Repo.one_for_update(query) do
          nil -> {:ok, :finished}
          op -> {:ok, record_timeout(op, error, apply)}
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

  defp record_timeout(op, error, apply) do
    if timed_out?(op) do
      # An older release could reopen a finished row after its timeout had taken effect.
      original = op.timeout_error || op.error

      op
      |> Ecto.Changeset.change(status: "failed", error: original, timeout_error: original)
      |> Repo.update!()

      :finished
    else
      failed =
        op
        |> Ecto.Changeset.change(
          status: "failed",
          error: error,
          timeout_error: op.timeout_error || error,
          args: Map.put(op.args || %{}, "timed_out", true),
          finished_at: op.finished_at || DateTime.utc_now()
        )
        |> Repo.update!()

      {failed, apply.(failed)}
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
      # A pre-upgrade timeout may have stored its first error only in the physical result.
      timeout_error: op.timeout_error || if(timed_out?(op), do: op.error),
      args: Map.delete(op.args || %{}, "timed_out"),
      # A late result reconciles the workspace. The public timeout already started retention.
      finished_at: op.finished_at || DateTime.utc_now()
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

  @doc """
  Merges `extra` into the args of an operation that's still on the box,
  for one sent again. A result that's already in is left alone.
  """
  def refresh_args(%Operation{} = op, extra) do
    from(o in Operation, where: o.id == ^op.id and o.status in ["dispatched", "running"])
    |> Repo.update_all(set: [args: Map.merge(op.args || %{}, extra)])

    :ok
  end

  @doc "Takes a queued operation for sending. `:error` if it isn't queued any more."
  def claim(%Operation{} = op, fields) do
    query = from o in Operation, where: o.id == ^op.id and o.status == "queued"

    # Command construction can block on external services. A deadline may
    # pass after selecting the operation but before this atomic claim.
    query =
      if op.trigger != "expiry" and
           op.action in ~w(create start rebuild pull_rebuild restart_all restart_affected) do
        due =
          from e in Foreman.Environments.Environment,
            where:
              e.id == ^op.environment_id and is_nil(e.destroyed_at) and
                is_nil(e.expiry_consumed_at) and e.expiry_at <= ^DateTime.utc_now()

        where(query, not exists(subquery(due)))
      else
        query
      end

    transition(op, query, [status: "dispatched"] ++ fields)
  end

  defp transition(op, from, fields) when is_binary(from) do
    transition(op, from(o in Operation, where: o.id == ^op.id and o.status == ^from), fields)
  end

  defp transition(op, query, fields) do
    case Repo.update_all(query, set: fields) do
      {1, _} -> {:ok, op.id |> get!() |> tap(&broadcast/1)}
      {0, _} -> :error
    end
  end

  @doc "Clears the logs and results of operations that finished before `cutoff`. Returns how many."
  def prune_output(cutoff) do
    minimum_window = Retention.log_cutoff(DateTime.utc_now())
    cutoff = if DateTime.after?(cutoff, minimum_window), do: minimum_window, else: cutoff

    {:ok, count} =
      Repo.transact(fn ->
        expired = from o in Operation, where: o.finished_at < ^cutoff
        chunk_ids = from c in LogStore, select: c.operation_id

        output =
          from o in expired,
            where: not is_nil(o.log) or not is_nil(o.result) or o.id in subquery(chunk_ids)

        {count, _} = Repo.update_all(output, set: [log: nil, result: nil])
        ids = select(expired, [o], o.id)
        Repo.delete_all(from c in LogStore, where: c.operation_id in subquery(ids))
        {:ok, count}
      end)

    count
  end

  def append_log(op_id, data), do: LogBuffer.append(op_id, data)

  @doc "The operation's full log, including anything not flushed yet."
  def log(%Operation{} = op), do: elem(LogBuffer.snapshot(op.id), 0)

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
