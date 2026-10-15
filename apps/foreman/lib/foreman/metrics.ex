defmodule Foreman.Metrics do
  @moduledoc """
  Box and environment usage over time, for the box charts.

  Agents send host metrics every 5 seconds (`box.metrics`) and
  per-environment usage every 30 (`box.stats`). Both are stored as they
  arrive and read back in time buckets sized so any range, 15 minutes or
  7 days, comes back as about #{240} points. `Foreman.Jobs.PruneMetrics`
  drops anything older than #{7} days.
  """
  import Ecto.Query

  alias Foreman.Metrics.{BoxMetric, EnvMetric}
  alias Foreman.Repo

  @ranges [
    {"15m", 15 * 60},
    {"30m", 30 * 60},
    {"1h", 3_600},
    {"3h", 3 * 3_600},
    {"8h", 8 * 3_600},
    {"1d", 86_400},
    {"3d", 3 * 86_400},
    {"7d", 7 * 86_400}
  ]
  @points 240
  @retention 7 * 86_400
  # Agent clocks further off than this are ignored in favour of ours.
  @max_skew 60

  def ranges, do: Enum.map(@ranges, &elem(&1, 0))
  def range_seconds(range), do: :proplists.get_value(range, @ranges, 3_600)

  @doc "The bucket size, in seconds, for a range: a multiple of the 5-second sample rate."
  def step(range) do
    raw = range_seconds(range) / @points
    max(5, ceil(raw / 5) * 5)
  end

  def subscribe(box_id), do: Phoenix.PubSub.subscribe(Foreman.PubSub, topic(box_id))
  def subscribe_all, do: Phoenix.PubSub.subscribe(Foreman.PubSub, "box_metrics")

  defp topic(box_id), do: "box_metrics:" <> box_id

  # -- writing -------------------------------------------------------------------

  @doc "Stores a `box.metrics` sample and broadcasts it as a chart point."
  def record_box(box_id, sample, now \\ System.system_time(:second)) do
    at = if abs(sample.at - now) > @max_skew, do: now, else: sample.at
    row = insert_box!(box_id, %{sample | at: at})
    point = point(row)

    Phoenix.PubSub.broadcast(Foreman.PubSub, topic(box_id), {:box_metrics, box_id, point})
    Phoenix.PubSub.broadcast(Foreman.PubSub, "box_metrics", {:box_metrics, box_id, point})
    :ok
  end

  @doc false
  def insert_box!(box_id, sample) do
    fields = BoxMetric.__schema__(:fields) -- [:box_id]

    attrs =
      sample
      |> Map.take(fields)
      |> Map.merge(%{
        box_id: box_id,
        cpu_percent: sample.cpu_percent * 1.0,
        load1: Map.get(sample, :load1, 0) * 1.0
      })

    Repo.insert!(struct(BoxMetric, attrs))
  end

  @doc "Stores per-environment usage: env_id => %{slug, cpu_percent, memory_mb}."
  def record_envs(box_id, usage, at \\ System.system_time(:second)) do
    rows =
      for {env_id, u} <- usage do
        %{
          box_id: box_id,
          env_id: env_id,
          slug: u.slug,
          at: at,
          cpu_percent: u.cpu_percent * 1.0,
          memory_mb: round(u.memory_mb)
        }
      end

    if rows != [], do: Repo.insert_all(EnvMetric, rows)
    :ok
  end

  @doc "Deletes samples older than the retention window. Returns {box, env} rows deleted."
  def prune(now \\ System.system_time(:second)) do
    cutoff = now - @retention
    {boxes, _} = Repo.delete_all(from m in BoxMetric, where: m.at < ^cutoff)
    {envs, _} = Repo.delete_all(from m in EnvMetric, where: m.at < ^cutoff)
    {boxes, envs}
  end

  # -- reading -------------------------------------------------------------------

  @doc """
  A box's host metrics over `range`, one point per bucket: average and
  peak CPU, load, memory and swap used (with their totals), and disk.
  """
  def box_series(box_id, range, now \\ System.system_time(:second)) do
    step = step(range)
    since = now - range_seconds(range)

    points =
      from(m in BoxMetric,
        where: m.box_id == ^box_id and m.at > ^since,
        group_by: fragment("bucket"),
        order_by: fragment("bucket"),
        select: %{
          at: fragment("? - (? % ?) AS bucket", m.at, m.at, ^step),
          cpu: type(avg(m.cpu_percent), :float),
          cpu_max: type(max(m.cpu_percent), :float),
          load1: type(avg(m.load1), :float),
          memory_used: type(avg(m.memory_used_mb), :float),
          memory_max: max(m.memory_used_mb),
          memory_total: max(m.memory_total_mb),
          swap_used: type(avg(m.swap_used_mb), :float),
          swap_total: max(m.swap_total_mb),
          disk_used: max(m.disk_used_mb),
          disk_total: max(m.disk_total_mb)
        }
      )
      |> Repo.all()
      |> Enum.map(&round_point/1)

    %{range: range, step: step, since: since, until: now, points: points}
  end

  @doc """
  Per-environment CPU and memory over `range`, heaviest memory first.
  Each series is `%{env_id, slug, cpu: [{at, percent}], memory: [{at, mb}]}`.
  """
  def env_series(box_id, range, now \\ System.system_time(:second)) do
    # Environment samples come every 30 seconds.
    step = max(step(range), 30)
    since = now - range_seconds(range)

    rows =
      from(m in EnvMetric,
        where: m.box_id == ^box_id and m.at > ^since,
        group_by: [m.env_id, fragment("bucket")],
        order_by: fragment("bucket"),
        select: %{
          env_id: m.env_id,
          slug: max(m.slug),
          at: fragment("? - (? % ?) AS bucket", m.at, m.at, ^step),
          cpu: type(avg(m.cpu_percent), :float),
          memory: type(avg(m.memory_mb), :float)
        }
      )
      |> Repo.all()

    series =
      rows
      |> Enum.group_by(& &1.env_id)
      |> Enum.map(fn {env_id, points} ->
        %{
          env_id: env_id,
          slug: List.last(points).slug,
          cpu: Enum.map(points, &{&1.at, Float.round(&1.cpu, 1)}),
          memory: Enum.map(points, &{&1.at, round(&1.memory)})
        }
      end)
      |> Enum.sort_by(fn s -> -Enum.sum_by(s.memory, &elem(&1, 1)) / max(length(s.memory), 1) end)

    %{range: range, step: step, since: since, until: now, series: series}
  end

  defp point(%BoxMetric{} = m) do
    %{
      at: m.at,
      cpu: m.cpu_percent * 1.0,
      cpu_max: m.cpu_percent * 1.0,
      load1: m.load1 * 1.0,
      memory_used: m.memory_used_mb,
      memory_max: m.memory_used_mb,
      memory_total: m.memory_total_mb,
      swap_used: m.swap_used_mb,
      swap_total: m.swap_total_mb,
      disk_used: m.disk_used_mb,
      disk_total: m.disk_total_mb
    }
  end

  defp round_point(p) do
    %{
      p
      | cpu: Float.round(p.cpu, 1),
        cpu_max: Float.round(p.cpu_max, 1),
        load1: Float.round(p.load1, 2),
        memory_used: round(p.memory_used),
        swap_used: round(p.swap_used)
    }
  end
end
