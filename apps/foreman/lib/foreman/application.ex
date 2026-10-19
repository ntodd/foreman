defmodule Foreman.Application do
  @moduledoc false
  use Boundary, top_level?: true, deps: [Foreman, ForemanWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ForemanWeb.Telemetry,
      Foreman.Vault,
      Foreman.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:foreman, :ecto_repos), skip: skip_migrations?()},
      %{
        id: :check_encryption_key,
        start: {Foreman.Settings, :start_checking_encryption_key, []},
        restart: :temporary
      },
      %{
        id: :register_bundled_agents,
        start: {Foreman.Agents.Releases, :start_registering_bundled, []},
        restart: :temporary
      },
      {Phoenix.PubSub, name: Foreman.PubSub},
      {Registry, keys: :unique, name: Foreman.Registry},
      {Foreman.RateLimit, clean_period: :timer.minutes(1)},
      Foreman.Agents.NonceCache,
      Foreman.Operations.Redactions,
      Foreman.Operations.LogBuffer,
      Foreman.Capacity.Tracker,
      {DynamicSupervisor, name: Foreman.Environments.Supervisor, strategy: :one_for_one},
      {Oban, Application.fetch_env!(:foreman, Oban)},
      Foreman.Setup,
      ForemanWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Foreman.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ForemanWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Releases migrate on boot; in dev and test, mix does it.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
