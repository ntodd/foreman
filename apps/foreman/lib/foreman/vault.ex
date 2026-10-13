defmodule Foreman.Vault do
  @moduledoc """
  Encryption at rest for secrets, GitHub tokens, registry credentials and
  stored keys (AES-256-GCM). The key comes from FOREMAN_ENCRYPTION_KEY.
  """
  use Cloak.Vault, otp_app: :foreman
end

defmodule Foreman.Encrypted.Binary do
  @moduledoc false
  use Cloak.Ecto.Binary, vault: Foreman.Vault
end

defmodule Foreman.Encrypted.Map do
  @moduledoc false
  use Cloak.Ecto.Map, vault: Foreman.Vault
end
