defmodule Foreman.Repo.Migrations.AddJoinTokenTailscaleKey do
  use Ecto.Migration

  # The Tailscale auth key a Flatcar box's first-boot config carries:
  # minted for the token by the control plane's OAuth client, or pasted
  # when the token was made. Encrypted like other secrets.
  def change do
    alter table(:join_tokens) do
      add :tailscale_auth_key, :binary
    end
  end
end
