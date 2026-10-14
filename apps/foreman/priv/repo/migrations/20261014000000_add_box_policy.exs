defmodule Foreman.Repo.Migrations.AddBoxPolicy do
  use Ecto.Migration

  # The compose policy each box's agent reports when it joins (rule =>
  # refuse, warn or allow). Null until an agent reports one.
  def change do
    alter table(:boxes) do
      add :policy, :map
    end
  end
end
