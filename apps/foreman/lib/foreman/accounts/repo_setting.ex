defmodule Foreman.Accounts.RepoSetting do
  @moduledoc """
  A user's overrides for one repo: git identity and dotfiles, and the
  features of their own they turn off here. Unset fields fall back to the
  user's defaults.
  """
  use Foreman.Schema

  schema "user_repo_settings" do
    belongs_to :user, Foreman.Accounts.User
    belongs_to :repo, Foreman.Repos.Repo
    field :git_name, :string
    field :git_email, :string
    field :dotfiles_repository, :string
    field :dotfiles_install_command, :string
    field :dotfiles_target_path, :string
    # By ref without a version, so a new version stays off.
    field :disabled_features, {:array, :string}, default: []
    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :git_name,
      :git_email,
      :dotfiles_repository,
      :dotfiles_install_command,
      :dotfiles_target_path,
      :disabled_features
    ])
    |> Foreman.Validations.validate_git_identity()
    |> Foreman.Validations.validate_dotfiles()
    |> Foreman.Validations.validate_feature_bases(:disabled_features)
    |> unique_constraint([:user_id, :repo_id])
  end
end
