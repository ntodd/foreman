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

  @vm_size ["FOREMAN_VM_DEFAULT_CPUS", "FOREMAN_VM_DEFAULT_MEMORY_MB"]

  setup do
    keys = Map.keys(@env) ++ ["FOREMAN_DB" | @vm_size]
    saved_env = Map.new(keys, &{&1, System.get_env(&1)})
    saved_database = Application.get_env(:foreman, :database)

    on_exit(fn ->
      for {k, v} <- saved_env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      Application.put_env(:foreman, :database, saved_database)
    end)

    Enum.each(["FOREMAN_DB" | @vm_size], &System.delete_env/1)
    System.put_env(@env)
    :ok
  end

  defp read_config do
    Config.Reader.read!(@runtime, env: :prod, target: :host)[:foreman]
  end

  defp read_repo_config, do: read_config()[Foreman.Repo]

  describe "the default VM size" do
    test "comes from FOREMAN_VM_DEFAULT_CPUS and FOREMAN_VM_DEFAULT_MEMORY_MB" do
      System.put_env("FOREMAN_VM_DEFAULT_CPUS", "2")
      System.put_env("FOREMAN_VM_DEFAULT_MEMORY_MB", "4096")

      config = read_config()
      assert config[:vm_default_cpus] == 2
      assert config[:vm_default_memory_mb] == 4096
    end

    test "is config.exs's when they're unset or empty" do
      System.put_env("FOREMAN_VM_DEFAULT_CPUS", "")

      config = read_config()
      refute Keyword.has_key?(config, :vm_default_cpus)
      refute Keyword.has_key?(config, :vm_default_memory_mb)
    end

    test "stops the release on a size that isn't a whole number above zero" do
      for value <- ["1.5", "0", "-2", "lots"] do
        System.put_env("FOREMAN_VM_DEFAULT_CPUS", value)
        assert_raise RuntimeError, ~r/FOREMAN_VM_DEFAULT_CPUS/, fn -> read_config() end
      end
    end
  end

  test "a release built for Postgres uses DATABASE_URL without FOREMAN_DB set at runtime" do
    Application.put_env(:foreman, :database, "postgres")

    repo = read_repo_config()
    assert repo[:url] == @env["DATABASE_URL"]
    refute repo[:database]
  end

  test "a release built for SQLite uses DATABASE_PATH" do
    Application.put_env(:foreman, :database, "sqlite")

    repo = read_repo_config()
    assert repo[:database] == "/var/lib/foreman/foreman.db"
    refute repo[:url]
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
