defmodule ForemanAgent.HostMetricsTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.HostMetrics

  @stat_1 """
  cpu  1000 0 500 8000 500 0 0 0 0 0
  cpu0 500 0 250 4000 250 0 0 0 0 0
  intr 12345
  """

  # 400 more busy jiffies (user+system), 600 more idle+iowait: 40% busy.
  @stat_2 """
  cpu  1300 0 600 8500 600 0 0 0 0 0
  cpu0 650 0 300 4250 300 0 0 0 0 0
  intr 12399
  """

  @meminfo """
  MemTotal:       16384000 kB
  MemFree:         2048000 kB
  MemAvailable:   10240000 kB
  Buffers:          512000 kB
  Cached:          6144000 kB
  SwapTotal:       2097152 kB
  SwapFree:        1048576 kB
  """

  test "reads total and idle CPU time from /proc/stat" do
    assert HostMetrics.cpu_times(@stat_1) == %{total: 10_000, idle: 8_500}
  end

  test "CPU percent is the busy share of time between two readings" do
    prev = HostMetrics.cpu_times(@stat_1)
    cur = HostMetrics.cpu_times(@stat_2)
    assert HostMetrics.cpu_percent(prev, cur) == 40.0
  end

  test "CPU percent is zero without a previous reading or when time didn't move" do
    cur = HostMetrics.cpu_times(@stat_2)
    assert HostMetrics.cpu_percent(nil, cur) == 0.0
    assert HostMetrics.cpu_percent(cur, cur) == 0.0
  end

  test "memory used is total minus available, so page cache doesn't count" do
    assert HostMetrics.memory(@meminfo) == %{
             memory_total_mb: 16_000,
             memory_used_mb: 6_000,
             swap_total_mb: 2_048,
             swap_used_mb: 1_024
           }
  end

  test "load is the one-minute average" do
    assert HostMetrics.load1("0.42 0.30 0.25 1/234 5678\n") == 0.42
    assert HostMetrics.load1("garbage") == 0
  end

  test "sample reads proc files and df, and carries the CPU reading forward" do
    dir = Path.join(System.tmp_dir!(), "host-metrics-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "stat"), @stat_1)
    File.write!(Path.join(dir, "meminfo"), @meminfo)
    File.write!(Path.join(dir, "loadavg"), "1.50 1.00 0.50 1/1 1\n")

    df = fn -> {100_000, 60_000} end

    {first, cpu} = HostMetrics.sample(%{proc: dir, disk: df, now: 1_760_500_000}, nil)
    assert first.cpu_percent == 0.0
    assert first.at == 1_760_500_000
    assert first.load1 == 1.5
    assert first.disk_total_mb == 100_000
    assert first.disk_used_mb == 40_000
    assert first.memory_used_mb == 6_000

    File.write!(Path.join(dir, "stat"), @stat_2)
    {second, _cpu} = HostMetrics.sample(%{proc: dir, disk: df, now: 1_760_500_005}, cpu)
    assert second.cpu_percent == 40.0
  end
end
