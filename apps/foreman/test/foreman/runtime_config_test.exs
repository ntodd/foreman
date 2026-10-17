defmodule Foreman.RuntimeConfigTest do
  @moduledoc """
  Evaluates config/runtime.exs for :prod the way a release does, with the
  environment docs/setup/team.md gives the control plane.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @env %{
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "FOREMAN_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
    "DATABASE_URL" => "ecto://user:pass@ep-example.us-east-2.aws.neon.tech/foreman",
    "PHX_HOST" => "foreman.tail1234.ts.net",
    "DATABASE_PATH" => "/var/lib/foreman/foreman.db"
  }

  setup do
    keys = Map.keys(@env) ++ ["FOREMAN_DB"]
    saved_env = Map.new(keys, &{&1, System.get_env(&1)})
    saved_database = Application.get_env(:foreman, :database)

    on_exit(fn ->
      for {k, v} <- saved_env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      Application.put_env(:foreman, :database, saved_database)
    end)

    System.delete_env("FOREMAN_DB")
    System.put_env(@env)
    :ok
  end

  defp read_repo_config do
    Config.Reader.read!(@runtime, env: :prod, target: :host)[:foreman][Foreman.Repo]
  end

  test "a release built for Postgres uses DATABASE_URL without FOREMAN_DB set at runtime" do
    Application.put_env(:foreman, :database, "postgres")

    repo = read_repo_config()
    assert repo[:url] == @env["DATABASE_URL"]
    refute repo[:database]
  end

  test "a release built for SQLite uses DATABASE_PATH" do
    Application.put_env(:foreman, :database, "sqlite")
    System.delete_env("DATABASE_URL")

    repo = read_repo_config()
    assert repo[:database] == "/var/lib/foreman/foreman.db"
    refute repo[:url]
  end

  # The SQLite image given a team's settings would come up on an empty
  # database, and its tailnet sweep would delete every environment's device.
  test "a release built for SQLite refuses a DATABASE_URL" do
    Application.put_env(:foreman, :database, "sqlite")

    assert_raise RuntimeError, ~r/built for SQLite; use the -pg image/, fn ->
      read_repo_config()
    end

    System.put_env("DATABASE_URL", "")
    assert read_repo_config()[:database] == "/var/lib/foreman/foreman.db"
  end

  test "FOREMAN_DB at runtime that disagrees with the build is refused" do
    Application.put_env(:foreman, :database, "sqlite")
    System.put_env("FOREMAN_DB", "postgres")

    assert_raise RuntimeError, ~r/built for sqlite/, fn -> read_repo_config() end
  end

  test "an empty FOREMAN_DB counts as unset" do
    Application.put_env(:foreman, :database, "postgres")
    System.put_env("FOREMAN_DB", "")

    assert read_repo_config()[:url] == @env["DATABASE_URL"]
  end
end
