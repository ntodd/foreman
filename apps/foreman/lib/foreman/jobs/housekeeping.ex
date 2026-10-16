defmodule Foreman.Jobs.Housekeeping do
  @moduledoc """
  Fails operations that were sent to a connected agent and never came
  back (the agent hung, or died mid-build and lost its in-memory state),
  so the environment's queue moves on; settles agent updates; and prunes
  expired join tokens, old sessions, old operation logs and the secrets
  kept for redacting finished operations.

  Operations on a box that's offline are left alone: they're resent when
  it reconnects. A result that turns up after an operation was failed
  here still counts (see `Foreman.Operations.finish/5`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query

  alias Foreman.{Agents, Boxes, Environments, Operations, Repo}
  alias Foreman.Boxes.Box
  alias Foreman.Operations.{Operation, Redactions}

  @stale_hours 3
  # Box commands (stats, inventory, cancel) are quick; their results come
  # straight after a reconnect if they come at all. A gc runs several
  # prunes, each allowed half an hour on the box.
  @box_command_minutes 10
  @gc_minutes 120
  @log_days 30

  @impl true
  def perform(_job) do
    fail_stale_environment_ops()
    fail_stale_box_ops()
    settle_updates()

    Repo.delete_all(
      from t in Boxes.JoinToken,
        where: t.expires_at < ^DateTime.add(DateTime.utc_now(), -86_400)
    )

    Repo.delete_all(
      from s in Foreman.Accounts.Session,
        where: s.inserted_at < ^DateTime.add(DateTime.utc_now(), -31 * 86_400)
    )

    Operations.prune_logs(DateTime.add(DateTime.utc_now(), -@log_days * 86_400))
    Redactions.prune()
    :ok
  end

  defp fail_stale_environment_ops do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_hours * 3600)

    stale =
      Repo.all(
        from o in Operation,
          where:
            o.status in ["dispatched", "running"] and not is_nil(o.environment_id) and
              o.dispatched_at < ^cutoff
      )

    for op <- stale, Boxes.online?(op.box_id) do
      # Stop whatever is still running on the box, so the next operation
      # doesn't run alongside it.
      Agents.cancel_operation(op, nil)

      with {:ok, op, env} <-
             Operations.timed_out(
               op,
               "no result after #{@stale_hours} hours",
               &Environments.record_result/1
             ),
           do: Environments.after_result(op, env)
    end
  end

  defp fail_stale_box_ops do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@box_command_minutes * 60)
    gc_cutoff = DateTime.add(now, -@gc_minutes * 60)

    Repo.all(
      from o in Operation,
        where:
          o.status in ["dispatched", "running"] and is_nil(o.environment_id) and
            o.action != "agent.update" and
            ((o.action != "box.gc" and o.dispatched_at < ^cutoff) or
               (o.action == "box.gc" and o.dispatched_at < ^gc_cutoff))
    )
    |> Enum.each(&Operations.timed_out(&1, "no result from the agent"))
  end

  defp settle_updates do
    Repo.all(
      from b in Box,
        join: o in Operation,
        on: o.box_id == b.id,
        where: o.action == "agent.update" and o.status in ["dispatched", "running"],
        distinct: true
    )
    |> Enum.each(&Agents.Releases.settle_updates/1)
  end
end
