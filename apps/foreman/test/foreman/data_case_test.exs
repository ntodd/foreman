defmodule Foreman.DataCaseTest do
  # The sandbox, not a feature: a test can start while the last test's
  # connection still holds SQLite's write lock (its rollback lands just
  # after), and that mustn't fail the new test's first write.
  use ExUnit.Case

  alias Foreman.Repo

  @moduletag skip: Repo.database() != "sqlite" && "SQLite's write lock only"

  test "a test that starts while another connection holds the write lock waits for it" do
    test_pid = self()

    holder =
      spawn_link(fn ->
        {:ok, conn} = Exqlite.Sqlite3.open(Repo.config()[:database])
        :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")
        send(test_pid, :locked)
        receive do: (:release -> :ok)
        :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
        :ok = Exqlite.Sqlite3.close(conn)
        send(test_pid, :released)
      end)

    assert_receive :locked
    Process.send_after(holder, :release, 200)
    Foreman.DataCase.setup_sandbox(%{async: false})

    # A read and then a write: a transaction that has read can't wait for
    # the lock, so SQLite answers "database busy" at once.
    refute Repo.exists?(Foreman.Repos.Owner)
    Foreman.Fixtures.owner_fixture()

    assert_receive :released
    refute Process.alive?(holder)
  end
end
