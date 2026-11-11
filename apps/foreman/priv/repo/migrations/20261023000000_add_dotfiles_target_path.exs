defmodule Foreman.Repo.Migrations.AddDotfilesTargetPath do
  use Ecto.Migration

  # Where the devcontainer CLI clones a user's dotfiles. Unset, it uses
  # ~/dotfiles, and dotfiles that expect ~/.dotfiles don't load.
  def change do
    alter table(:users) do
      add :dotfiles_target_path, :string
    end

    alter table(:user_repo_settings) do
      add :dotfiles_target_path, :string
    end
  end
end
