import Config

# Runtime configuration, read from the environment. See docs/setup/ for
# what each deployment sets.

list = fn name ->
  name |> System.get_env("") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

if System.get_env("PHX_SERVER") do
  config :foreman, ForemanWeb.Endpoint, server: true
end

config :foreman, ForemanWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  config :foreman, ForemanWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"lib/foreman_web/router\.ex$"E,
        ~r"lib/foreman_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# Settings every environment reads (dev and prod), with defaults that suit
# a single-user personal deployment.
if config_env() != :test do
  config :foreman,
    slug_style: if(System.get_env("FOREMAN_SLUG_STYLE") == "team", do: :team, else: :personal),
    admins: list.("FOREMAN_ADMINS"),
    allowed_users: list.("FOREMAN_ALLOWED_USERS"),
    allowed_org: System.get_env("FOREMAN_ALLOWED_ORG"),
    git_base_url: System.get_env("FOREMAN_GIT_BASE_URL", "https://github.com"),
    agent_release_public_key: System.get_env("FOREMAN_AGENT_RELEASE_PUBLIC_KEY"),
    agent_release_dir: System.get_env("FOREMAN_AGENT_RELEASE_DIR"),
    github_app: %{
      app_id: System.get_env("FOREMAN_GITHUB_APP_ID"),
      client_id: System.get_env("FOREMAN_GITHUB_CLIENT_ID"),
      client_secret: System.get_env("FOREMAN_GITHUB_CLIENT_SECRET"),
      private_key:
        System.get_env("FOREMAN_GITHUB_PRIVATE_KEY") ||
          (System.get_env("FOREMAN_GITHUB_PRIVATE_KEY_FILE") &&
             File.read!(System.get_env("FOREMAN_GITHUB_PRIVATE_KEY_FILE")))
    },
    tailscale: %{
      client_id: System.get_env("FOREMAN_TAILSCALE_CLIENT_ID"),
      client_secret: System.get_env("FOREMAN_TAILSCALE_CLIENT_SECRET"),
      tailnet: System.get_env("FOREMAN_TAILSCALE_TAILNET", "-"),
      tags: list.("FOREMAN_TAILSCALE_TAGS")
    }
end

if config_env() == :prod do
  if System.get_env("FOREMAN_DB", "sqlite") == "postgres" do
    url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is missing"
    host = URI.parse(url).host

    # TLS with certificate checks by default (Neon requires TLS).
    ssl =
      if System.get_env("DATABASE_SSL", "true") == "true" do
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host)
        ]
      else
        false
      end

    config :foreman, Foreman.Repo,
      url: url,
      ssl: ssl,
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  else
    config :foreman, Foreman.Repo,
      database: System.get_env("DATABASE_PATH", "/var/lib/foreman/foreman.db"),
      pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing; generate one with: mix phx.gen.secret"

  # 32 random bytes, base64. Encrypts secrets, tokens and keys at rest.
  #     openssl rand -base64 32
  encryption_key =
    System.get_env("FOREMAN_ENCRYPTION_KEY") ||
      raise "FOREMAN_ENCRYPTION_KEY is missing; generate one with: openssl rand -base64 32"

  config :foreman, Foreman.Vault,
    ciphers: [
      default:
        {Cloak.Ciphers.AES.GCM,
         tag: "AES.GCM.V1", key: Base.decode64!(encryption_key), iv_length: 12}
    ]

  host =
    System.get_env("PHX_HOST") ||
      raise "PHX_HOST is missing (the tailnet host name, e.g. foreman.tail1234.ts.net)"

  # Listens on loopback by default: put `tailscale serve` in front of it
  # for HTTPS on the tailnet. Set FOREMAN_LISTEN_IP to the box's tailnet
  # address to listen there directly instead.
  {:ok, ip} =
    System.get_env("FOREMAN_LISTEN_IP", "127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()

  config :foreman,
    force_ssl: System.get_env("FOREMAN_FORCE_SSL", "true") == "true",
    secure_cookies: System.get_env("FOREMAN_SECURE_COOKIES", "true") == "true",
    # Overrides the https://PHX_HOST base URL agents and GitHub are given.
    base_url: System.get_env("FOREMAN_BASE_URL")

  config :foreman, ForemanWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: ip],
    check_origin: ["https://" <> host | String.split(System.get_env("FOREMAN_EXTRA_ORIGINS", ""), ",", trim: true)],
    secret_key_base: secret_key_base
end
