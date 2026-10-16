defmodule Foreman.Repo.Migrations.AddBoxFailedAgentVersion do
  use Ecto.Migration

  # The agent version a box was sent and didn't come back on (it crashed
  # and systemd rolled it back). It isn't sent again until an admin picks
  # a version for the box again.
  def change do
    alter table(:boxes) do
      add :failed_agent_version, :string
    end
  end
end
