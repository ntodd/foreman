defmodule Foreman.Repo do
  @database Application.compile_env(:foreman, :database, "sqlite")

  use Ecto.Repo,
    otp_app: :foreman,
    adapter: if(@database == "postgres", do: Ecto.Adapters.Postgres, else: Ecto.Adapters.SQLite3)

  import Ecto.Query

  # SQLite takes its write lock when the transaction begins. On Postgres
  # lock the row before checking a credential that can be consumed or rotated.
  def one_for_update(query) do
    one(if sqlite?(), do: query, else: from(row in query, lock: "FOR UPDATE"))
  end

  @doc ~s|The database this build was compiled for: "sqlite" or "postgres".|
  def database, do: @database

  def sqlite?, do: @database == "sqlite"
end
