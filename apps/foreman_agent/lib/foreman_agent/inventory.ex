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
    |> Enum.group_by(fn {env_id, slug, _, _} -> {env_id, slug} end, fn {_, _, c, done?} ->
      {c, done?}
    end)
    |> Enum.map(fn {{env_id, slug}, containers} ->
      %{
        env_id: env_id,
        slug: slug,
        state: state(containers),
        containers: containers |> Enum.map(&elem(&1, 0)) |> Enum.sort_by(& &1.service)
      }
    end)
  end

  defp parse(%{"Id" => id, "State" => state, "Labels" => labels} = container)
       when is_map(labels) do
    case Schema.cast(
           %{"env_id" => labels["foreman.env_id"], "slug" => labels["foreman.slug"]},
           env_id: {:uuid, required: true},
           slug: {:slug, required: true}
         ) do
      {:ok, %{env_id: env_id, slug: slug}} ->
        service = labels["com.docker.compose.service"] || "unknown"
        done? = labels["foreman.devcontainer"] != "true" and completed?(state, container)
        [{env_id, slug, %{id: id, service: service, state: state}, done?}]

      {:error, _} ->
        []
    end
  end

  defp parse(_), do: []

  # Ran to completion: an init or migration job that did its work and
  # exited. Docker's list only has the exit code in Status.
  defp completed?("exited", %{"Status" => "Exited (0)" <> _}), do: true
  defp completed?(_state, _container), do: false

  # running, stopped or partial. A container that ran to completion
  # doesn't count either way: it isn't down, and it isn't running.
  defp state(containers) do
    left = for {c, false} <- containers, do: c
    running = Enum.count(left, &(&1.state == "running"))

    cond do
      running == 0 -> "stopped"
      running == length(left) -> "running"
      true -> "partial"
    end
  end
end
