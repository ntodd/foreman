defmodule Foreman.Repo.Migrations.CreateGitHubSignInGenerations do
  use Ecto.Migration

  def change do
    create table(:github_sign_in_generations, primary_key: false) do
      add :github_id, :bigint, primary_key: true, null: false
      add :generation, :bigint, null: false, default: 0
    end
  end
end
