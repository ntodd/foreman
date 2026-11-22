defmodule Foreman.Repo.Migrations.RemoveDestroyedEnvironmentSecrets do
  use Ecto.Migration

  def up do
    execute """
    DELETE FROM secrets WHERE scope = 'environment' AND environment_id IN
      (SELECT id FROM environments WHERE destroyed_at IS NOT NULL)
    """
  end

  def down, do: :ok
end
