defmodule Foreman.Jobs.RefreshTokens do
  @moduledoc """
  Scoped GitHub tokens can't be refreshed, and the user tokens they come
  from last 8 hours, so every environment gets a freshly scoped token
  (with its other files) when its last one is over four hours old. Each
  token it gets lasts at least five (`GitHub.environment_token/2`).

  Environments of users whose own token has expired or will before the
  next run are pushed to as well, whatever their age, so one that was
  handed a short-lived token doesn't wait hours with a dead one.
  """
  use Oban.Worker, queue: :github, max_attempts: 3, unique: [period: 600]

  import Ecto.Query

  alias Foreman.Accounts.User

  # The job runs every 30 minutes.
  @next_run 30 * 60

  @impl true
  def perform(_job) do
    if Foreman.GitHub.configured?() do
      now = DateTime.utc_now()
      Foreman.Environments.push_secrets(older_than: DateTime.add(now, -4 * 3600))

      for user_id <- users_with_expiring_tokens(DateTime.add(now, @next_run)),
          do: Foreman.Environments.push_secrets(user_id: user_id)
    end

    :ok
  end

  defp users_with_expiring_tokens(cutoff) do
    from(u in User,
      where:
        u.github_login_expired == false and is_nil(u.disabled_at) and
          u.access_token_expires_at < ^cutoff,
      select: u.id
    )
    |> Foreman.Repo.all()
  end
end
