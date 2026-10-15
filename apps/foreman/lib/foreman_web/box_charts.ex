defmodule ForemanWeb.BoxCharts do
  @moduledoc """
  The box usage charts: CPU and memory (box totals over each running
  environment's share), disk, and load against the core count.
  """
  use Phoenix.Component

  import ForemanWeb.Charts

  alias ForemanWeb.Charts.Geometry

  # Past this many environments, the smallest fold into "Other".
  @max_envs 7

  attr :box, :map, required: true
  attr :series, :map, required: true, doc: "Metrics.box_series/3"
  attr :envs, :map, required: true, doc: "Metrics.env_series/3"
  attr :latest, :map, default: nil, doc: "the newest sample, for the headlines"

  def usage(assigns) do
    %{series: series, envs: envs, box: box} = assigns
    points = series.points
    latest = assigns.latest || List.last(points)
    cap = box.capacity || %{}
    cpus = max(cap["cpus"] || 1, 1)
    gap = series.step * 3
    env_gap = envs.step * 3
    envs = fold(envs.series)

    mem_total = (latest && latest.memory_total) || cap["memory_mb"] || 1
    disk_total = (latest && latest.disk_total) || cap["disk_mb"] || 1

    peak_cpu = points |> Enum.map(& &1.cpu_max) |> Enum.max(fn -> nil end)
    peak_load = points |> Enum.map(& &1.load1) |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(since: series.since, until: series.until, gap: gap)
      |> assign(:latest, latest)
      |> assign(:cpus, cpus)
      |> assign(
        :cpu_series,
        bands(envs, :cpu, &(&1 / cpus), env_gap) ++
          [line("Box total", Enum.map(points, &{&1.at, &1.cpu}))]
      )
      |> assign(:cpu_note, peak_cpu && "Peak #{pct(peak_cpu)} in this range")
      |> assign(
        :memory_series,
        bands(envs, :memory, & &1, env_gap) ++
          [line("Box total", Enum.map(points, &{&1.at, &1.memory_used}))]
      )
      |> assign(:mem_total, mem_total)
      |> assign(:memory_note, memory_note(latest, mem_total))
      |> assign(:disk_series, [line("Used", Enum.map(points, &{&1.at, &1.disk_used}))])
      |> assign(:disk_total, disk_total)
      |> assign(:load_series, [line("Load", Enum.map(points, &{&1.at, &1.load1}))])
      |> assign(:load_max, Geometry.nice_max(max(cpus, peak_load) * 1.1))

    ~H"""
    <div class="grid gap-4 xl:grid-cols-2">
      <.timeseries
        id="cpu-chart"
        title="CPU"
        value={@latest && pct(@latest.cpu)}
        note={@cpu_note}
        series={@cpu_series}
        since={@since}
        until={@until}
        ymax={100}
        gap={@gap}
        format={&pct/1}
      />
      <.timeseries
        id="memory-chart"
        title="Memory"
        value={@latest && gib(@latest.memory_used)}
        note={@memory_note}
        series={@memory_series}
        since={@since}
        until={@until}
        ymax={@mem_total}
        gap={@gap}
        format={&gib/1}
      />
      <.timeseries
        id="disk-chart"
        title="Disk"
        value={@latest && gib(@latest.disk_used)}
        note={@latest && "of #{gib(@disk_total)}, #{gib(@disk_total - @latest.disk_used)} free"}
        series={@disk_series}
        since={@since}
        until={@until}
        ymax={@disk_total}
        gap={@gap}
        format={&gib/1}
      />
      <.timeseries
        id="load-chart"
        title="Load"
        value={@latest && load(@latest.load1)}
        note="One-minute average. Above the core count, work is waiting for a CPU."
        series={@load_series}
        since={@since}
        until={@until}
        ymax={@load_max}
        gap={@gap}
        format={&load/1}
        ref={%{value: @cpus, label: "#{@cpus} #{if @cpus == 1, do: "core", else: "cores"}"}}
      />
    </div>
    """
  end

  defp line(label, points),
    do: %{label: label, kind: :line, color: accent_color(), points: points}

  # Stacked environment bands, colored by slug so a color sticks to its
  # environment whatever the order.
  defp bands(envs, key, scale, gap) do
    colors =
      envs
      |> Enum.reject(&(&1.slug == :other))
      |> Enum.map(& &1.slug)
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new(fn {slug, i} -> {slug, series_color(i)} end)

    stacked =
      envs
      |> Enum.map(fn env -> Enum.map(Map.fetch!(env, key), fn {at, v} -> {at, scale.(v)} end) end)
      |> Geometry.stack()

    Enum.zip_with(envs, stacked, fn env, points ->
      %{
        label: if(env.slug == :other, do: "Other", else: env.slug),
        kind: :area,
        color: if(env.slug == :other, do: other_color(), else: colors[env.slug]),
        gap: gap,
        points: points
      }
    end)
  end

  defp fold(series) when length(series) <= @max_envs, do: series

  defp fold(series) do
    {top, rest} = Enum.split(series, @max_envs - 1)

    sum = fn key ->
      rest
      |> Enum.flat_map(&Map.fetch!(&1, key))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {at, vs} -> {at, Enum.sum(vs)} end)
      |> Enum.sort()
    end

    top ++ [%{env_id: nil, slug: :other, cpu: sum.(:cpu), memory: sum.(:memory)}]
  end

  defp memory_note(nil, _total), do: nil

  defp memory_note(latest, total) do
    swap = if latest.swap_used > 0, do: ", #{gib(latest.swap_used)} swap", else: ""
    "of #{gib(total)}#{swap}"
  end

  def pct(v), do: "#{round(v)}%"
  def gib(mb), do: ForemanWeb.ForemanComponents.gib(mb) <> " GiB"
  def load(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)
end
