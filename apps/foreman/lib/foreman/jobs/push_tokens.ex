defmodule Foreman.Jobs.PushTokens do
  @moduledoc """
  Sends a user's running environments a fresh GitHub token after the
  user's own token was rotated. GitHub revokes the old token when it's
  refreshed, and environments given it (repos in broad token mode) still
  hold it. Scoped tokens are re-scoped too: it costs a request per
  environment, a few times a day.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 60, keys: [:user_id]]

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id}}),
    do: Foreman.Environments.push_secrets(user_id: user_id)
end
