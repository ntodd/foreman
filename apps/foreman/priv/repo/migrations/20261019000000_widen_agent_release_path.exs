defmodule Foreman.Repo.Migrations.WidenAgentReleasePath do
  use Ecto.Migration

  # A stored tarball's path is FOREMAN_AGENT_RELEASE_DIR plus its file
  # name, which can pass 255 characters. SQLite doesn't enforce a varchar's
  # length, and can't alter a column.
  def change do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      alter table(:agent_releases) do
        modify :path, :text, null: false, from: {:string, null: false}
      end
    end
  end
end
