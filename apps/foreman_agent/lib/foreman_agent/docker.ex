defmodule ForemanAgent.Docker do
  @moduledoc """
  The parts of the Docker Engine API the agent reads: containers and
  networks by label, daemon info, per-container stats, and a container's details and
  processes. Everything that changes state goes
  through the docker and devcontainer CLIs via `ForemanAgent.Runner`.
  """

  @callback list_containers(labels :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback list_networks(filters :: map()) :: {:ok, [map()]} | {:error, term()}
  @callback info() :: {:ok, map()} | {:error, term()}
  @callback stats(container_id :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback inspect_container(container_id :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback top(container_id :: String.t()) :: {:ok, [pos_integer()]} | {:error, term()}

  def impl, do: Application.get_env(:foreman_agent, :docker, ForemanAgent.Docker.Engine)

  def list_containers(labels), do: impl().list_containers(labels)
  def list_networks(filters), do: impl().list_networks(filters)
  def info, do: impl().info()
  def stats(id), do: impl().stats(id)
  def inspect_container(id), do: impl().inspect_container(id)
  def top(id), do: impl().top(id)
end
