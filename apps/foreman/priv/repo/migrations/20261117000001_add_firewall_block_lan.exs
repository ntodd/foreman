defmodule Foreman.Repo.Migrations.AddFirewallBlockLan do
  use Ecto.Migration

  def change do
    alter table(:boxes) do
      add :firewall_block_lan, :boolean
    end
  end
end
