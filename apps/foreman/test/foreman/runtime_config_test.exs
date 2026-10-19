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
    keys =
      Map.keys(@env) ++
        ["FOREMAN_DB", "FOREMAN_TAILSCALE_DEPLOYMENT_TAG", "FOREMAN_ENCRYPTION_KEYS_RETIRED"]

    saved_env = Map.new(keys, &{&1, System.get_env(&1)})
    saved_database = Application.get_env(:foreman, :database)

    on_exit(fn ->
      for {k, v} <- saved_env, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      Application.put_env(:foreman, :database, saved_database)
    end)

    System.delete_env("FOREMAN_DB")
    System.delete_env("FOREMAN_ENCRYPTION_KEYS_RETIRED")
    System.put_env(@env)
    :ok
  end

  defp read_config, do: Config.Reader.read!(@runtime, env: :prod, target: :host)[:foreman]

  defp read_repo_config, do: read_config()[Foreman.Repo]

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

  test "FOREMAN_TAILSCALE_DEPLOYMENT_TAG sets the deployment tag" do
    Application.put_env(:foreman, :database, "postgres")
    System.put_env("FOREMAN_TAILSCALE_DEPLOYMENT_TAG", "tag:foreman-dev")

    assert read_config()[:tailscale][:deployment_tag] == "tag:foreman-dev"
  end

  # A typo would leave the sweep off without saying so, and an auth key
  # with a tag the OAuth client doesn't own fails every create.
  test "a FOREMAN_TAILSCALE_DEPLOYMENT_TAG that isn't a tag is refused" do
    Application.put_env(:foreman, :database, "postgres")
    System.put_env("FOREMAN_TAILSCALE_DEPLOYMENT_TAG", "foreman-dev")

    assert_raise RuntimeError, ~r/FOREMAN_TAILSCALE_DEPLOYMENT_TAG/, fn -> read_config() end
  end

  defp vault_keys do
    Application.put_env(:foreman, :database, "postgres")
    {Foreman.Vault.Cipher, opts} = read_config()[Foreman.Vault][:ciphers][:default]
    opts[:keys]
  end

  test "FOREMAN_ENCRYPTION_KEY is the key everything is encrypted with" do
    assert vault_keys() == [Base.decode64!(@env["FOREMAN_ENCRYPTION_KEY"])]
  end

  # It would boot, and the first encryption (saving the GitHub App at
  # the end of setup, after the manifest code is spent) would fail.
  test "a FOREMAN_ENCRYPTION_KEY that isn't 32 bytes is refused" do
    for key <- [
          # SECRET_KEY_BASE's recipe, and `openssl rand -hex 32`
          Base.encode64(:crypto.strong_rand_bytes(48)),
          Base.encode16(:crypto.strong_rand_bytes(32)),
          Base.encode64(:crypto.strong_rand_bytes(16))
        ] do
      System.put_env("FOREMAN_ENCRYPTION_KEY", key)

      assert_raise RuntimeError, ~r/FOREMAN_ENCRYPTION_KEY is \d+ bytes, not 32/, fn ->
        vault_keys()
      end
    end
  end

  test "a FOREMAN_ENCRYPTION_KEY that isn't base64 is refused" do
    System.put_env("FOREMAN_ENCRYPTION_KEY", "not base64!")

    assert_raise RuntimeError, ~r/FOREMAN_ENCRYPTION_KEY isn't base64/, fn -> vault_keys() end
  end

  test "a trailing newline on FOREMAN_ENCRYPTION_KEY is ignored" do
    System.put_env("FOREMAN_ENCRYPTION_KEY", @env["FOREMAN_ENCRYPTION_KEY"] <> "\n")

    assert vault_keys() == [Base.decode64!(@env["FOREMAN_ENCRYPTION_KEY"])]
  end

  test "FOREMAN_ENCRYPTION_KEYS_RETIRED are kept for reading, after the current key" do
    old = for _ <- 1..2, do: :crypto.strong_rand_bytes(32)
    System.put_env("FOREMAN_ENCRYPTION_KEYS_RETIRED", Enum.map_join(old, ", ", &Base.encode64/1))

    assert vault_keys() == [Base.decode64!(@env["FOREMAN_ENCRYPTION_KEY"]) | old]
  end

  test "a retired key that isn't 32 bytes is refused" do
    System.put_env("FOREMAN_ENCRYPTION_KEYS_RETIRED", Base.encode64("short"))

    assert_raise RuntimeError, ~r/FOREMAN_ENCRYPTION_KEYS_RETIRED/, fn -> vault_keys() end
  end
end
