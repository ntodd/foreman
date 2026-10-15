defmodule ForemanAgent.HostMetrics do
  @moduledoc """
  Host-wide CPU, memory, swap, load and disk, read from /proc and df.
  Cheap enough to sample every few seconds; nothing here goes through
  Docker.

  CPU is a rate, so each sample needs the previous /proc/stat reading:
  `sample/2` takes it and returns the new one to pass next time.
  """

  @type cpu :: %{total: non_neg_integer(), idle: non_neg_integer()} | nil

  @doc """
  One sample. `source` has `:proc` (the /proc directory), `:disk` (a
  function returning `{total_mb, free_mb}`) and `:now` (Unix seconds).
  """
  @spec sample(map(), cpu()) :: {map(), cpu()}
  def sample(source, prev_cpu) do
    cpu = source.proc |> read("stat") |> cpu_times()
    {disk_total, disk_free} = source.disk.()

    metrics =
      %{
        at: source.now,
        cpu_percent: cpu_percent(prev_cpu, cpu),
        load1: source.proc |> read("loadavg") |> load1(),
        disk_total_mb: disk_total,
        disk_used_mb: max(disk_total - disk_free, 0)
      }
      |> Map.merge(source.proc |> read("meminfo") |> memory())

    {metrics, cpu}
  end

  @doc "Total and idle (idle + iowait) jiffies from the aggregate `cpu` line."
  def cpu_times(stat) do
    with [line | _] <- Regex.run(~r/^cpu\s+(.+)$/m, stat, capture: :all_but_first),
         [user, nice, system, idle, iowait | rest] <-
           line |> String.split() |> Enum.map(&String.to_integer/1) do
      # guest and guest_nice are already counted in user and nice.
      steal_irq = rest |> Enum.take(3) |> Enum.sum()
      %{total: user + nice + system + idle + iowait + steal_irq, idle: idle + iowait}
    else
      _ -> nil
    end
  end

  @doc "Busy share of CPU time between two readings, 0-100."
  def cpu_percent(%{total: t0, idle: i0}, %{total: t1, idle: i1}) when t1 > t0 do
    busy = t1 - t0 - (i1 - i0)
    Float.round(max(busy, 0) / (t1 - t0) * 100, 1)
  end

  def cpu_percent(_prev, _cur), do: 0.0

  @doc "Memory and swap in MB. Used memory is total minus MemAvailable."
  def memory(meminfo) do
    kb = parse_meminfo(meminfo)
    total = mb(kb["MemTotal"])
    swap_total = mb(kb["SwapTotal"])

    %{
      memory_total_mb: total,
      memory_used_mb: max(total - mb(kb["MemAvailable"] || kb["MemFree"]), 0),
      swap_total_mb: swap_total,
      swap_used_mb: max(swap_total - mb(kb["SwapFree"]), 0)
    }
  end

  @doc "The one-minute load average, or 0 if unreadable."
  def load1(loadavg) do
    with [first | _] <- String.split(loadavg),
         {load, ""} <- Float.parse(first) do
      load
    else
      _ -> 0
    end
  end

  defp parse_meminfo(text) do
    for line <- String.split(text, "\n", trim: true),
        [key, value | _] <- [String.split(line, [":", " "], trim: true)],
        {kb, ""} <- [Integer.parse(value)],
        into: %{},
        do: {key, kb}
  end

  defp mb(nil), do: 0
  # MiB, like the rest of the agent's memory figures.
  defp mb(kb), do: div(kb, 1024)

  defp read(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end
end
