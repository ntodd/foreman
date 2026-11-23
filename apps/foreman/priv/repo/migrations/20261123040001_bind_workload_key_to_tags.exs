defmodule Foreman.Repo.Migrations.BindWorkloadKeyToTags do
  use Ecto.Migration

  def change do
    alter table(:environments), do: add(:ts_authkey_tags, {:array, :string})
  end
end
