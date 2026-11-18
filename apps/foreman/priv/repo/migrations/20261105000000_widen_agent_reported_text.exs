defmodule Foreman.Repo.Migrations.WidenAgentReportedText do
  use Ecto.Migration

  # What an up result reports (the remote user, workspace folder, service
  # names and policy warnings) comes from the repo's devcontainer and the
  # box's policy, at any length, and so does a nested devcontainer path
  # from GitHub. Postgres refuses a varchar(255) overflow, which failed
  # the whole result. SQLite doesn't enforce a varchar's length, and
  # can't alter a column.
  def change do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      alter table(:environments) do
        modify :remote_user, :text, from: :string
        modify :workspace_folder, :text, from: :string
        modify :devcontainer_service, :text, from: :string
        modify :services, {:array, :text}, null: false, default: [], from: {:array, :string}
        modify :warnings, {:array, :text}, null: false, default: [], from: {:array, :string}
      end

      alter table(:repos) do
        modify :devcontainer_path, :text, from: :string
      end
    end
  end
end
