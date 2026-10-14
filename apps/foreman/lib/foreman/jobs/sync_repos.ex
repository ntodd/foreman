defmodule Foreman.Jobs.SyncRepos do
  @moduledoc "Polls the GitHub App's installations for repos and devcontainers (Foreman has no public webhook endpoint)."
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 300]

  @impl true
  def perform(_job) do
    if Foreman.GitHub.configured?() do
      case Foreman.GitHub.sync_repos() do
        {:ok, _count} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end
end
