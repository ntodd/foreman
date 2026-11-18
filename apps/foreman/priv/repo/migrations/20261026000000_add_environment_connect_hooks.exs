defmodule Foreman.Repo.Migrations.AddEnvironmentConnectHooks do
  use Ecto.Migration

  # The connect hooks (ForemanProtocol.Connect) the agent found in the
  # environment's devcontainer when it last came up.
  def change do
    alter table(:environments) do
      add :connect_hooks, {:array, :map}, null: false, default: []
    end
  end
end
