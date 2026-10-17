defmodule ForemanAgent.Stats do
  @moduledoc """
  Box capacity (cores, memory, disk) and live usage per environment,
  summed over each environment's running containers.
  """

  alias ForemanAgent.Env

  require Logger

  @spec collect(map()) :: {:ok, map()} | {:error, String.t()}
  def collect(%{config: %{isolation: :vm}} = ctx), do: Env.Vm.stats(ctx)

  def collect(ctx) do
    with {:ok, info} <- ctx.docker.info(),
         {:ok, containers} <- ctx.docker.list_containers(["foreman.env_id"]) do
      {disk_mb, free_mb} = disk(ctx)

      {:ok,
       %{
         capacity: %{
           cpus: info["NCPU"] || 0,
           memory_mb: div(info["MemTotal"] || 0, 1024 * 1024),
           disk_mb: disk_mb,
           disk_free_mb: free_mb
         },
         environments: usage(ctx, containers)
       }}
    else
      {:error, reason} -> {:error, "couldn't read Docker stats: #{inspect(reason)}"}
    end
  end

  defp usage(ctx, containers) do
    containers
    |> Enum.filter(&(&1["State"] == "running" and env_label?(&1)))
    |> Task.async_stream(
      fn c -> {c["Labels"]["foreman.env_id"], container_usage(ctx, c["Id"])} end,
      max_concurrency: 8,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {env_id, {cpu, mem}}}, acc ->
        Map.update(acc, env_id, %{cpu_percent: cpu, memory_mb: mem}, fn e ->
          %{cpu_percent: e.cpu_percent + cpu, memory_mb: e.memory_mb + mem}
        end)

      _, acc ->
        acc
    end)
    |> Map.new(fn {k, v} -> {k, %{v | cpu_percent: Float.round(v.cpu_percent * 1.0, 2)}} end)
  end

  # One container with a label that isn't an environment id (made by hand,
  # say) would make the whole box.stats event invalid. Leave it out, and
  # say so once.
  defp env_label?(%{"Id" => id, "Labels" => labels}) do
    case ForemanProtocol.Schema.cast(%{"id" => labels["foreman.env_id"]},
           id: {:uuid, required: true}
         ) do
      {:ok, _} ->
        true

      {:error, _} ->
        if labels["foreman.env_id"] && :persistent_term.get({__MODULE__, :stray, id}, nil) == nil do
          :persistent_term.put({__MODULE__, :stray, id}, true)

          Logger.warning(
            "container #{id} has foreman.env_id #{inspect(labels["foreman.env_id"])}, " <>
              "which isn't an environment id; leaving it out of the stats"
          )
        end

        false
    end
  end

  defp env_label?(_container), do: false

  defp container_usage(ctx, id) do
    case ctx.docker.stats(id) do
      {:ok, stats} -> {cpu_percent(stats), memory_mb(stats)}
      {:error, _} -> {0.0, 0}
    end
  end

  defp cpu_percent(%{"cpu_stats" => cpu, "precpu_stats" => pre}) do
    cpu_delta =
      get_in(cpu, ["cpu_usage", "total_usage"]) - (get_in(pre, ["cpu_usage", "total_usage"]) || 0)

    system_delta = (cpu["system_cpu_usage"] || 0) - (pre["system_cpu_usage"] || 0)
    cpus = cpu["online_cpus"] || 1

    if system_delta > 0 and cpu_delta > 0, do: cpu_delta / system_delta * cpus * 100, else: 0.0
  end

  defp cpu_percent(_), do: 0.0

  # Page cache (inactive_file on cgroup v2, cache on v1) isn't really in use.
  defp memory_mb(%{"memory_stats" => %{"usage" => usage} = mem}) do
    stats = mem["stats"] || %{}
    cache = stats["inactive_file"] || stats["total_inactive_file"] || stats["cache"] || 0
    div(max(usage - cache, 0), 1024 * 1024)
  end

  defp memory_mb(_), do: 0

  @doc "Total and free MB on the filesystem holding the environments."
  def disk(ctx) do
    # A hung filesystem (a dead NFS mount) can hang df.
    case ctx.runner.run("df", ["-Pk", ctx.config.envs_root], env: %{}, timeout: 10_000) do
      {:ok, %{status: 0, output: output}} -> parse_df(output)
      _ -> {0, 0}
    end
  end

  defp parse_df(output) do
    with [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, total, _used, avail | _] <- String.split(line),
         {total, ""} <- Integer.parse(total),
         {avail, ""} <- Integer.parse(avail) do
      {div(total, 1024), div(avail, 1024)}
    else
      _ -> {0, 0}
    end
  end
end
