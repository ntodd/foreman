defmodule ForemanAgent.Inventory do
  @moduledoc """
  Turns Docker's container list into the environments on this box.
  Docker labels are the agent's only record of what exists.
  """

  alias ForemanProtocol.Schema

  @spec from_containers([map()]) :: [map()]
  def from_containers(containers) do
    containers
    |> Enum.flat_map(&parse/1)
    |> Enum.group_by(fn {env_id, slug, _} -> {env_id, slug} end, fn {_, _, c} -> c end)
    |> Enum.map(fn {{env_id, slug}, containers} ->
      %{
        env_id: env_id,
        slug: slug,
        state: state(containers),
        containers: Enum.sort_by(containers, & &1.service)
      }
    end)
  end

  defp parse(%{"Id" => id, "State" => state, "Labels" => labels}) when is_map(labels) do
    case Schema.cast(
           %{"env_id" => labels["foreman.env_id"], "slug" => labels["foreman.slug"]},
           env_id: {:uuid, required: true},
           slug: {:slug, required: true}
         ) do
      {:ok, %{env_id: env_id, slug: slug}} ->
        service = labels["com.docker.compose.service"] || "unknown"
        [{env_id, slug, %{id: id, service: service, state: state}}]

      {:error, _} ->
        []
    end
  end

  defp parse(_), do: []

  @doc "running, stopped or partial, from a list of container states."
  def state(containers) do
    running = Enum.count(containers, &(&1.state == "running"))

    cond do
      running == length(containers) -> "running"
      running == 0 -> "stopped"
      true -> "partial"
    end
  end
end
