defmodule Foreman.OAuth.GrantRepository do
  @moduledoc "The local repository and GitHub identity observed when a service installation was approved."
  use Ecto.Schema

  @primary_key false
  schema "oauth_grant_repositories" do
    field :grant_id, :binary_id, primary_key: true
    field :repo_id, :binary_id, primary_key: true
    field :github_id, :integer
  end
end
