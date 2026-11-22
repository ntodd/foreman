defmodule Foreman.Repo.Migrations.WidenPrebuildConfigPath do
  use Ecto.Migration

  def change do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      alter table(:prebuilds) do
        modify :config_path, :text, null: false, from: {:string, null: false}
      end
    end
  end
end
