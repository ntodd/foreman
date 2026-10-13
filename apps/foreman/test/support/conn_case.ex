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
        {:ok, conn: Phoenix.ConnTest.build_conn()}
      end
    end
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
