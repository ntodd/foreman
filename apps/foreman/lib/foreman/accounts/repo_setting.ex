defmodule Foreman.Accounts.RepoSetting do
  @moduledoc """
  A user's overrides for one repo: git identity and dotfiles. Unset fields
  fall back to the user's defaults.
  """
  use Foreman.Schema

  schema "user_repo_settings" do
    belongs_to :user, Foreman.Accounts.User
    belongs_to :repo, Foreman.Repos.Repo
    field :git_name, :string
    field :git_email, :string
    field :dotfiles_repository, :string
    field :dotfiles_install_command, :string
    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:git_name, :git_email, :dotfiles_repository, :dotfiles_install_command])
    |> Foreman.Validations.validate_git_identity()
    |> Foreman.Validations.validate_dotfiles()
    |> unique_constraint([:user_id, :repo_id])
  end
end
