defmodule ForemanAgent.Docker.Engine do
  @moduledoc "`ForemanAgent.Docker` over the Engine API's unix socket."
  @behaviour ForemanAgent.Docker

  @impl true
  def list_containers(labels) do
    filters = JSON.encode!(%{"label" => labels})
    get("/containers/json", all: true, filters: filters)
  end

  @impl true
  def list_networks(filters), do: get("/networks", filters: JSON.encode!(filters))

  @impl true
  def info, do: get("/info", [])

  @impl true
  def stats(id) do
    if Regex.match?(~r/\A[0-9a-f]{12,64}\z/, id),
      do: get("/containers/#{id}/stats", stream: false),
      else: {:error, :invalid_id}
  end

  @impl true
  def inspect_container(id) do
    if Regex.match?(~r/\A[0-9a-f]{12,64}\z/, id),
      do: get("/containers/#{id}/json", []),
      else: {:error, :invalid_id}
  end

  @doc "The host pids of a container's processes."
  @impl true
  def top(id) do
    with true <- Regex.match?(~r/\A[0-9a-f]{12,64}\z/, id) || {:error, :invalid_id},
         {:ok, %{"Titles" => titles, "Processes" => processes}} <-
           get("/containers/#{id}/top", ps_args: "-o pid"),
         column when is_integer(column) <-
           Enum.find_index(titles, &(&1 == "PID")) || {:error, :no_pid} do
      {:ok,
       for(
         row <- processes,
         {pid, ""} <- [Integer.parse(Enum.at(row, column, ""))],
         pid > 0,
         do: pid
       )}
    end
  end

  defp get(path, params) do
    case Req.get(req(), url: path, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp req do
    Req.new(
      base_url: "http://docker",
      unix_socket: ForemanAgent.Config.get().docker_socket,
      retry: false,
      receive_timeout: 15_000
    )
  end
end
