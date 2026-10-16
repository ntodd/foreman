defmodule Foreman.Jobs.Dispatch do
  @moduledoc """
  A safety net for dispatch: every minute, environments with queued
  operations on a connected box get a kick, so work queued from another
  process (a release `eval`, say) or a missed kick never sits forever.
  Connected boxes due an agent update get it once they're idle.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query

  alias Foreman.Boxes.Box
  alias Foreman.Operations.Operation
  alias Foreman.Repo

  @impl true
  def perform(_job) do
    queued =
      Repo.all(
        from o in Operation,
          where: o.status == "queued" and not is_nil(o.environment_id),
          distinct: true,
          select: {o.environment_id, o.box_id}
      )

    for {env_id, box_id} <- queued, Foreman.Boxes.online?(box_id) do
      Foreman.Environments.Server.kick(env_id)
    end

    due =
      Repo.all(
        from b in Box,
          where:
            is_nil(b.revoked_at) and not is_nil(b.desired_agent_version) and
              (is_nil(b.agent_version) or b.desired_agent_version != b.agent_version)
      )

    for box <- due, Foreman.Boxes.online?(box.id), do: Foreman.Agents.Releases.maybe_update(box)

    :ok
  end
end
