import Config

# The control plane's database: SQLite (the default, one file next to the
# app) or Postgres. Chosen at compile time, because Ecto fixes a repo's
# adapter when the repo compiles; a release is built for one or the other.
#
#     FOREMAN_DB=postgres mix compile
database = System.get_env("FOREMAN_DB", "sqlite")

unless database in ["sqlite", "postgres"] do
  raise "FOREMAN_DB must be sqlite or postgres, got #{inspect(database)}"
end

config :foreman,
  database: database,
  ecto_repos: [Foreman.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

config :foreman, Foreman.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

# SQLite: transactions take the write lock when they begin. A deferred
# one that reads and then writes fails at once ("database busy", which
# busy_timeout doesn't cover) if anything else wrote in between. Taking
# the lock up front means writers queue instead, so give them longer than
# the 2s default before an agent channel gives up and reconnects.
if database == "sqlite" do
  config :foreman, Foreman.Repo, default_transaction_mode: :immediate, busy_timeout: 15_000
end

config :foreman, Oban,
  engine: if(database == "sqlite", do: Oban.Engines.Lite, else: Oban.Engines.Basic),
  notifier: if(database == "sqlite", do: Oban.Notifiers.PG, else: Oban.Notifiers.Postgres),
  repo: Foreman.Repo,
  queues: [default: 10, github: 5, tailscale: 2],
  plugins: [
    # Dispatch alone finishes a job a minute, so keep an hour of history:
    # long enough for every worker's unique period, and the Jobs page.
    {Oban.Plugins.Pruner, max_age: 60 * 60},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/30 * * * *", Foreman.Jobs.RefreshTokens},
       {"41 */6 * * *", Foreman.Jobs.CheckAccess},
       {"*/15 * * * *", Foreman.Jobs.SyncRepos},
       {"7 * * * *", Foreman.Jobs.CleanupTailnet},
       {"*/5 * * * *", Foreman.Jobs.Housekeeping},
       {"23 * * * *", Foreman.Jobs.PruneMetrics},
       {"* * * * *", Foreman.Jobs.Dispatch},
       {"*/5 * * * *", Foreman.Jobs.CheckForUpdates}
     ]}
  ]

# How environments are named: "personal" gives <repo>-<n>, "team" gives
# <repo>-<login>-<n> so developers' environments never collide.
config :foreman, :slug_style, :personal

config :foreman, ForemanWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ForemanWeb.ErrorHTML, json: ForemanWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Foreman.PubSub,
  live_view: [signing_salt: "ayoi0W5m"]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  foreman: [
    args:
      ~w(js/app.js js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.3",
  foreman: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :env_id, :op_id, :box_id]

config :phoenix, :json_library, Jason

# Kept out of request logs: join tokens (and the Tailscale keys and
# first-boot configs that come with them), secrets, passwords.
config :phoenix, :filter_parameters, ["password", "token", "secret", "auth_key"]

import_config "#{config_env()}.exs"
