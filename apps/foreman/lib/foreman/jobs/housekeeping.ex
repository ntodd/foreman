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

  alias Foreman.{Agents, Boxes, Environments, Operations, Prebuilds, Repo}
  alias Foreman.Boxes.Box
  alias Foreman.Operations.{Operation, Redactions}

  @stale_hours 3
  # A connect hook's action is bounded at four minutes on the box; one that
  # never came back is from an agent that can't run it (an older one).
  @connect_minutes 10
  # Box commands (stats, inventory, cancel) are quick; their results come
  # straight after a reconnect if they come at all. A gc runs several
  # prunes, each allowed half an hour on the box.
  @box_command_minutes 10
  @gc_minutes 120
  # A prebuild clones and builds a devcontainer from nothing, which the
  # agent gives up to four hours.
  @prebuild_minutes 300
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

    Operations.prune_output(DateTime.add(DateTime.utc_now(), -@log_days * 86_400))
    Redactions.prune()
    :ok
  end

  defp fail_stale_environment_ops do
    fail_stale_environment_ops(
      DateTime.add(DateTime.utc_now(), -@stale_hours * 3600),
      "no result after #{@stale_hours} hours",
      dynamic([o], o.action != "connect")
    )

    fail_stale_environment_ops(
      DateTime.add(DateTime.utc_now(), -@connect_minutes * 60),
      "no result after #{@connect_minutes} minutes",
      dynamic([o], o.action == "connect")
    )
  end

  defp fail_stale_environment_ops(cutoff, message, which) do
    stale =
      Repo.all(
        from o in Operation,
          where:
            o.status in ["dispatched", "running"] and not is_nil(o.environment_id) and
              o.dispatched_at < ^cutoff,
          where: ^which
      )

    # The list is from before the loop, and a reconnect may have restarted an
    # operation's clock since: it's failed only if it's still overdue, and
    # cancelled on the box only once it has been.
    for op <- stale, Boxes.online?(op.box_id) do
      with {:ok, failed, env} <-
             Operations.timed_out(
               op,
               message,
               &Environments.record_result/1,
               dispatched_before: cutoff
             ) do
        # Stop whatever is still running on the box before the next
        # operation goes out, so they don't run side by side.
        Agents.cancel_operation(op, nil)
        Environments.after_result(failed, env)
      end
    end
  end

  defp fail_stale_box_ops do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@box_command_minutes * 60)
    gc_cutoff = DateTime.add(now, -@gc_minutes * 60)
    prebuild_cutoff = DateTime.add(now, -@prebuild_minutes * 60)
    long = ["box.gc", "box.prebuild"]

    Repo.all(
      from o in Operation,
        where:
          o.status in ["dispatched", "running"] and is_nil(o.environment_id) and
            o.action != "agent.update" and
            ((o.action not in ^long and o.dispatched_at < ^cutoff) or
               (o.action == "box.gc" and o.dispatched_at < ^gc_cutoff) or
               (o.action == "box.prebuild" and o.dispatched_at < ^prebuild_cutoff))
    )
    |> Enum.each(fn op ->
      with {:ok, failed, recorded} <-
             Operations.timed_out(op, "no result from the agent", &Prebuilds.record_result/1) do
        Prebuilds.after_result(recorded)
        # A build still running on the box stops there too, so its VM
        # doesn't run on (the box's agent gives its VM back).
        if failed.action == "box.prebuild", do: Agents.cancel_operation(op, nil)
      end
    end)
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
