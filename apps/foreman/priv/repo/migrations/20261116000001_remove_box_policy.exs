defmodule Foreman.Repo.Migrations.RemoveBoxPolicy do
  use Ecto.Migration

  # The compose policy agents reported (protocol 5 and before) went with
  # shared Docker: every environment runs in a VM of its own now.
  def change do
    alter table(:boxes) do
      remove :policy, :map
    end
  end
end
