defmodule Foreman.DataCaseTest do
  # Sets up its own sandbox, to begin it while another connection holds
  # the write lock.
  use ExUnit.Case, async: false

  import Foreman.Fixtures

  alias Exqlite.Sqlite3

  if Foreman.Repo.database() != "sqlite", do: @moduletag(skip: "SQLite's write lock")

  # The previous test's connection is rolled back after that test is
  # over, so a test can begin while it still holds the write lock. One
  # that reads before it writes mustn't fail with "database busy".
  test "a test that reads before it writes waits for another writer to finish" do
    {:ok, other} = Sqlite3.open(Foreman.Repo.config()[:database])
    on_exit(fn -> Sqlite3.close(other) end)
    :ok = Sqlite3.set_busy_timeout(other, 30_000)
    :ok = Sqlite3.execute(other, "BEGIN IMMEDIATE")

    spawn(fn ->
      Process.sleep(200)
      Sqlite3.execute(other, "ROLLBACK")
    end)

    Foreman.DataCase.setup_sandbox(%{async: false})

    assert Foreman.Repos.get_owner_by_login("acme") == nil
    assert %{login: "acme"} = owner_fixture(login: "acme")
  end
end
