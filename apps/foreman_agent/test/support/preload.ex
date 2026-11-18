defmodule ForemanAgent.Test.Preload do
  @moduledoc """
  Loads the agent's code, and the code of every application it runs on,
  before the tests start, the way a release in embedded mode (the default
  `RELEASE_MODE`) loads everything as it boots.

  `mix test` loads a module the first time something calls it. Early in a
  run the code server is busy with the test files as they compile, and a
  process making its first call into a module waits behind them: on a
  slow runner, longer than the second a test gives it to reply.
  """

  @doc "Loads every module of `apps/0`."
  @spec load!() :: :ok
  def load! do
    apps()
    |> Enum.flat_map(&(Application.spec(&1, :modules) || []))
    |> Code.ensure_all_loaded!()
  end

  @doc "`:foreman_agent` and the applications it depends on, all the way down."
  @spec apps() :: [atom()]
  def apps, do: apps([:foreman_agent], [])

  defp apps([], seen), do: seen

  defp apps([app | rest], seen) do
    if app in seen do
      apps(rest, seen)
    else
      deps =
        for key <- [:applications, :included_applications],
            dep <- Application.spec(app, key) || [],
            do: dep

      apps(deps ++ rest, [app | seen])
    end
  end
end
