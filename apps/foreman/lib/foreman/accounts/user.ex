defmodule Foreman.Accounts.User do
  @moduledoc "A person who signs in with GitHub."
  use Foreman.Schema

  @roles ~w(admin member)

  schema "users" do
    field :github_id, :integer
    field :login, :string
    field :name, :string
    field :avatar_url, :string
    field :role, :string, default: "member"
    field :access_token, Foreman.Encrypted.Binary, redact: true
    field :access_token_expires_at, :utc_datetime_usec
    field :refresh_token, Foreman.Encrypted.Binary, redact: true
    field :refresh_token_expires_at, :utc_datetime_usec
    field :github_login_expired, :boolean, default: false
    field :git_name, :string
    field :git_email, :string
    field :dotfiles_repository, :string
    field :dotfiles_install_command, :string
    field :dotfiles_target_path, :string
    field :devcontainer_features, :map, default: %{}
    field :disabled_at, :utc_datetime_usec
    timestamps()
  end

  def roles, do: @roles

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(_), do: false

  def github_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :github_id,
      :login,
      :name,
      :avatar_url,
      :access_token,
      :access_token_expires_at,
      :refresh_token,
      :refresh_token_expires_at,
      :github_login_expired
    ])
    |> validate_required([:login])
    |> unique_constraint(:login)
    |> unique_constraint(:github_id)
  end

  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :disabled_at])
    |> validate_inclusion(:role, @roles)
  end

  @doc "Features go on all of the user's environments: ref => options, as in devcontainer.json."
  def features_changeset(user, features) when is_map(features) do
    user
    |> cast(%{devcontainer_features: features}, [:devcontainer_features])
    |> Foreman.Validations.validate_features(:devcontainer_features)
  end

  def features_changeset(user, _features) do
    user
    |> change()
    |> add_error(:devcontainer_features, "must be an object of feature refs and their options")
  end

  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :git_name,
      :git_email,
      :dotfiles_repository,
      :dotfiles_install_command,
      :dotfiles_target_path
    ])
    |> Foreman.Validations.validate_git_identity()
    |> Foreman.Validations.validate_dotfiles()
  end
end
