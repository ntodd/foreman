defmodule Foreman.Secrets.Secret do
  @moduledoc """
  A secret at one scope: owner, repo, user or environment. The value is
  encrypted at rest and never read back by the UI. A user secret can apply
  to all of the user's environments or only to selected repos.
  """
  use Foreman.Schema

  @scopes ~w(owner repo user environment)

  schema "secrets" do
    field :scope, :string
    field :scope_key, :string
    belongs_to :owner, Foreman.Repos.Owner
    belongs_to :repo, Foreman.Repos.Repo
    belongs_to :user, Foreman.Accounts.User
    belongs_to :environment, Foreman.Environments.Environment
    field :name, :string
    field :value, Foreman.Encrypted.Binary, redact: true
    field :repo_ids, {:array, :string}, default: []
    belongs_to :updated_by, Foreman.Accounts.User
    timestamps()
  end

  def scopes, do: @scopes

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :value, :repo_ids])
    |> validate_required([:name, :value])
    |> Foreman.Validations.validate_env_name(:name)
    |> validate_length(:value, max: 65_536, count: :bytes)
    |> validate_format(:value, ~r/\A[^\0]*\z/, message: "can't contain NUL bytes")
    |> unique_constraint([:scope_key, :name], error_key: :name, message: "already exists here")
  end
end
