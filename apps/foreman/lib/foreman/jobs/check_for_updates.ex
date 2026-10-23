defmodule Foreman.Jobs.CheckForUpdates do
  @moduledoc """
  Looks for a newer Foreman release (`Foreman.Updates.check/0`). Every
  five minutes while self-update is new; a failed check isn't retried,
  the next one is soon enough.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  @impl true
  def perform(_job) do
    if Foreman.Updates.enabled?(), do: Foreman.Updates.check()
    :ok
  end
end
