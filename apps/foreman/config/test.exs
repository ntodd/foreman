import Config

if System.get_env("FOREMAN_DB", "sqlite") == "postgres" do
  config :foreman, Foreman.Repo,
    url:
      System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/foreman_test") <>
        "#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
else
  config :foreman, Foreman.Repo,
    database: Path.expand("../foreman_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
    pool_size: 5,
    # Each sandboxed test holds a transaction, which takes the write lock
    # when it begins (see config.exs); async tests wait for each other.
    busy_timeout: 30_000,
    pool: Ecto.Adapters.SQL.Sandbox
end

config :foreman, Oban, testing: :manual

config :foreman, ForemanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e/Y5OfWQvLQ62yfWWoqWxf2uf5xbDAh/05h3jTT3BKyCPDKEikFPkDG7Xe2K4lFD",
  server: false

config :foreman, Foreman.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("vT8f4ZpX3m2Qb9yR1sL0kW7cH5nJ6dA4eG2tU8iO3xM="),
       iv_length: 12}
  ]

config :foreman,
  env: :test,
  github_client: Foreman.GitHub.ClientMock,
  tailscale_client: Foreman.Tailscale.ClientMock,
  agent_release_public_key: nil

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true,
  test_warnings: [missing_form_id: :raise]

config :phoenix, sort_verified_routes_query_params: true
config :foreman, sync_dispatch: true
