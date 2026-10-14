defmodule Foreman.Repos.Owner do
  @moduledoc """
  A GitHub account (org or user) whose repos Foreman knows about, with the
  GitHub App installation and the registry credential for private images.
  """
  use Foreman.Schema

  schema "owners" do
    field :login, :string
    field :kind, :string, default: "User"
    field :github_id, :integer
    field :installation_id, :integer
    field :registry_host, :string
    field :registry_username, :string
    field :registry_token, Foreman.Encrypted.Binary, redact: true
    field :registry_token_expires_at, :utc_datetime_usec
    field :registry_scopes, :string
    field :registry_checked_at, :utc_datetime_usec
    field :registry_error, :string
    has_many :repos, Foreman.Repos.Repo
    timestamps()
  end

  def changeset(owner, attrs) do
    owner
    |> cast(attrs, [:login, :kind, :github_id, :installation_id])
    |> validate_required([:login])
    |> validate_format(:login, ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/)
    |> unique_constraint(:login)
  end

  def registry_changeset(owner, attrs) do
    owner
    |> cast(attrs, [
      :registry_host,
      :registry_username,
      :registry_token,
      :registry_token_expires_at,
      :registry_scopes,
      :registry_checked_at,
      :registry_error
    ])
    |> validate_format(:registry_host, ~r/\A[a-z0-9.-]+(:\d+)?\z/)
    |> validate_format(:registry_username, ~r/\A[A-Za-z0-9-]{1,39}\z/)
  end
end
