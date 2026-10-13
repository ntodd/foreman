defmodule Foreman.Jobs.RefreshTokens do
  @moduledoc """
  Scoped GitHub tokens can't be refreshed, and the user tokens they come
  from last 8 hours, so every environment gets a freshly scoped token
  (with its other files) when its last one is over four hours old.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 600]

  @impl true
  def perform(_job) do
    if Foreman.GitHub.configured?() do
      Foreman.Environments.push_secrets(older_than: DateTime.add(DateTime.utc_now(), -4 * 3600))
    end

    :ok
  end
end
