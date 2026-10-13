defmodule Foreman.DataCase do
  @moduledoc """
  Tests that use the database. Each test runs in a sandboxed transaction.

  `async: true` is honoured on Postgres only: SQLite has a single writer,
  so concurrent sandboxed transactions would wait on each other's locks.
  """

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false) and Foreman.Repo.database() == "postgres"

    quote do
      use ExUnit.Case, async: unquote(async)

      alias Foreman.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Foreman.DataCase
      import Foreman.Fixtures

      setup tags do
        Foreman.DataCase.setup_sandbox(tags)
        :ok
      end
    end
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Foreman.Repo, shared: not tags[:async])
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    # Runs first (on_exit is last in, first out): stop the environment
    # servers a test started while the sandbox is still there.
    ExUnit.Callbacks.on_exit(&stop_environment_servers/0)
  end

  def stop_environment_servers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Foreman.Environments.Supervisor) do
      DynamicSupervisor.terminate_child(Foreman.Environments.Supervisor, pid)
    end

    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
