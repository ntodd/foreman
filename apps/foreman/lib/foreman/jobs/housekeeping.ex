defmodule Foreman.Jobs.Housekeeping do
  @moduledoc """
  Fails operations that were sent to an agent and never came back (the
  agent died mid-build and lost its in-memory state), so the environment's
  queue moves on, and prunes expired join tokens and old sessions.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query

  alias Foreman.Operations.Operation
  alias Foreman.Repo

  @stale_hours 3

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_hours * 3600)

    stale =
      Repo.all(
        from o in Operation,
          where: o.status in ["dispatched", "running"] and o.dispatched_at < ^cutoff
      )

    for op <- stale do
      op =
        Foreman.Operations.mark(op, "failed",
          error: "no result after #{@stale_hours} hours",
          finished_at: DateTime.utc_now()
        )

      Foreman.Environments.apply_result(op)
    end

    Repo.delete_all(
      from t in Foreman.Boxes.JoinToken,
        where: t.expires_at < ^DateTime.add(DateTime.utc_now(), -86_400)
    )

    Repo.delete_all(
      from s in Foreman.Accounts.Session,
        where: s.inserted_at < ^DateTime.add(DateTime.utc_now(), -31 * 86_400)
    )

    :ok
  end
end
