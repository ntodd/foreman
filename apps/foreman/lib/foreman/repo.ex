defmodule Foreman.Repo do
  @database Application.compile_env(:foreman, :database, "sqlite")

  use Ecto.Repo,
    otp_app: :foreman,
    adapter: if(@database == "postgres", do: Ecto.Adapters.Postgres, else: Ecto.Adapters.SQLite3)

  @doc ~s|The database this build was compiled for: "sqlite" or "postgres".|
  def database, do: @database

  def sqlite?, do: @database == "sqlite"
end
