defmodule Foreman.Settings do
  @moduledoc """
  Deployment settings kept in the database, encrypted: the GitHub App's
  credentials (when created through the manifest flow), Tailscale's OAuth
  client, and similar. Environment variables take precedence where both
  exist.
  """
  alias Foreman.Repo
  alias Foreman.Settings.Setting

  def get(key, default \\ nil) do
    case Repo.get(Setting, key) do
      %Setting{value: %{"v" => value}} -> value
      _ -> default
    end
  end

  def put(key, value) do
    %Setting{key: key}
    |> Ecto.Changeset.change(value: %{"v" => value})
    |> Repo.insert!(on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)

    :ok
  end

  def delete(key) do
    case Repo.get(Setting, key) do
      nil -> :ok
      setting -> Repo.delete!(setting) && :ok
    end
  end
end
