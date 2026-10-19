defmodule Foreman.Repo.Migrations.AddBoxFirewall do
  use Ecto.Migration

  # The box firewall each box's agent reports when it joins: whether it's
  # loaded ("active", "outdated" or "missing") and whether it leaves
  # Docker's default bridge out ("filtered" or "reaches_tailnet"). Null
  # until an agent on protocol 3 reports them.
  def change do
    alter table(:boxes) do
      add :firewall, :string
      add :firewall_default_bridge, :string
    end
  end
end
