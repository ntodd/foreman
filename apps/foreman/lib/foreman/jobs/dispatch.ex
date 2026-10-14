defmodule Foreman.Jobs.Dispatch do
  @moduledoc """
  A safety net for dispatch: every minute, environments with queued
  operations on a connected box get a kick, so work queued from another
  process (a release `eval`, say) or a missed kick never sits forever.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query

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

    :ok
  end
end
