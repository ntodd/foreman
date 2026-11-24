defmodule ForemanWeb.ConnCase do
  @moduledoc """
  Tests that need a connection (controllers and LiveViews). See
  `Foreman.DataCase` for why `async: true` only applies on Postgres.
  """

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false) and Foreman.Repo.database() == "postgres"

    quote do
      use ExUnit.Case, async: unquote(async)

      @endpoint ForemanWeb.Endpoint

      use ForemanWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import ForemanWeb.ConnCase
      import Foreman.Fixtures

      setup tags do
        Foreman.DataCase.setup_sandbox(tags)
        # Each test gets its own client address, so rate limits (kept in
        # ETS for the whole run) never carry over from another test.
        client = {10, :rand.uniform(254), :rand.uniform(254), :rand.uniform(254)}
        {:ok, conn: %{Phoenix.ConnTest.build_conn() | remote_ip: client}}
      end
    end
  end

  @doc """
  Waits, if it must, until at least `needed` ms are left in the current
  `window` of `Foreman.RateLimit`.

  Its windows are fixed and start on the wall clock's multiples of the
  window, so every counter starts again from nothing at each one. A test
  that sends a limit's worth of requests and expects the last to be
  refused has to send them all inside one window.
  """
  def within_one_window(window \\ 60_000, needed \\ 15_000) do
    left = window - rem(System.system_time(:millisecond), window)
    if left < needed, do: Process.sleep(left + 10)
    :ok
  end

  @doc "Signs `user` in on `conn`."
  def log_in(conn, user) do
    token = Foreman.Accounts.create_session(user, "test")

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:session_token, token)
  end

  def register_and_log_in(%{conn: conn}) do
    user = Foreman.Fixtures.user_fixture()
    %{conn: log_in(conn, user), user: user}
  end

  def register_and_log_in_admin(%{conn: conn}) do
    user = Foreman.Fixtures.user_fixture(role: "admin")
    %{conn: log_in(conn, user), user: user}
  end
end
