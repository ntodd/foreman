import Config

config :foreman_agent,
  # Base64 ed25519 public key that agent releases are signed with. Set at
  # build time; CI injects the real one.
  release_public_key: System.get_env("FOREMAN_RELEASE_PUBLIC_KEY")

config :logger, :default_formatter,
  format: "$time [$level] $metadata$message\n",
  metadata: [:op_id]

import_config "#{config_env()}.exs"
