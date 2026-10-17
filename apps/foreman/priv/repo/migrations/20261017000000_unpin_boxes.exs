defmodule Foreman.Repo.Migrations.UnpinBoxes do
  use Ecto.Migration

  # A box's desired agent version used to be the only way to roll an
  # agent out, and blank meant "leave it alone". Blank now means "follow
  # the agent this control plane carries", and a version pins the box.
  # A version set before meant "roll this out", never "hold it here", so
  # every box follows from now on, including ones that were part way
  # through a rollout or offline for it.
  def up do
    execute "UPDATE boxes SET desired_agent_version = NULL WHERE desired_agent_version IS NOT NULL"
  end

  def down, do: :ok
end
