defmodule Foreman.MetricsTest do
  use Foreman.DataCase

  alias Foreman.Metrics

  @now 1_760_500_000

  defp sample(at, attrs \\ %{}) do
    Map.merge(
      %{
        at: at,
        cpu_percent: 10.0,
        load1: 0.5,
        memory_total_mb: 16_000,
        memory_used_mb: 4_000,
        swap_total_mb: 0,
        swap_used_mb: 0,
        disk_total_mb: 100_000,
        disk_used_mb: 40_000
      },
      attrs
    )
  end

  describe "record_box/3" do
    test "stores a sample and broadcasts it to the box's subscribers" do
      box = box_fixture()
      Metrics.subscribe(box.id)

      assert :ok = Metrics.record_box(box.id, sample(@now), @now)
      assert_receive {:box_metrics, box_id, %{cpu: 10.0, at: @now}}
      assert box_id == box.id

      assert %{points: [%{cpu: 10.0}]} = Metrics.box_series(box.id, "15m", @now)
    end

    test "uses the control plane's clock when the agent's is far off" do
      box = box_fixture()
      Metrics.record_box(box.id, sample(@now - 3_600), @now)

      assert %{points: [%{at: at}]} = Metrics.box_series(box.id, "15m", @now)
      assert at > @now - 60
    end
  end

  describe "box_series/3" do
    test "buckets samples so every range comes back as a bounded number of points" do
      box = box_fixture()

      # Every 5 seconds for an hour, CPU climbing from 0 to 71.9.
      for i <- 0..719 do
        Metrics.insert_box!(box.id, sample(@now - 3_595 + i * 5, %{cpu_percent: i / 10}))
      end

      %{step: step, points: points} = Metrics.box_series(box.id, "1h", @now)
      assert step == 15
      assert length(points) in 239..241

      # Each bucket has the average and the peak of the samples in it.
      [first | _] = points
      assert first.cpu_max >= first.cpu
      assert_in_delta List.last(points).cpu, 71.8, 0.2

      %{points: short} = Metrics.box_series(box.id, "15m", @now)
      assert Enum.all?(short, &(&1.at >= @now - 900))
    end

    test "has ranges from 15 minutes to 7 days" do
      assert Metrics.ranges() == ~w(15m 30m 1h 3h 8h 1d 3d 7d)
      box = box_fixture()

      for range <- Metrics.ranges(),
          do: assert(%{points: []} = Metrics.box_series(box.id, range, @now))
    end

    test "returns memory and disk with their totals" do
      box = box_fixture()
      Metrics.record_box(box.id, sample(@now), @now)

      assert %{points: [p]} = Metrics.box_series(box.id, "15m", @now)

      assert %{memory_used: 4_000, memory_total: 16_000, disk_used: 40_000, disk_total: 100_000} =
               p
    end
  end

  describe "env_series/3" do
    test "breaks usage down by environment, by slug, even after one is gone" do
      box = box_fixture()
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      for i <- 0..9 do
        Metrics.record_envs(
          box.id,
          %{
            a => %{slug: "shop-1", cpu_percent: 50.0, memory_mb: 1_000},
            b => %{slug: "shop-2", cpu_percent: 10.0, memory_mb: 3_000}
          },
          @now - i * 30
        )
      end

      %{series: series} = Metrics.env_series(box.id, "15m", @now)
      by_slug = Map.new(series, &{&1.slug, &1})

      assert %{cpu: cpu, memory: mem} = by_slug["shop-1"]
      assert Enum.all?(cpu, fn {_at, v} -> v == 50.0 end)
      assert Enum.all?(mem, fn {_at, v} -> v == 1_000 end)
      # Heaviest memory first, so stacks and legends stay in a stable order.
      assert [%{slug: "shop-2"}, %{slug: "shop-1"}] = series
    end
  end

  describe "prune/1" do
    test "deletes box and environment samples older than seven days" do
      box = box_fixture()
      old = @now - 8 * 86_400
      env = Ecto.UUID.generate()

      Metrics.insert_box!(box.id, sample(old))
      Metrics.insert_box!(box.id, sample(@now))
      Metrics.record_envs(box.id, %{env => %{slug: "x-1", cpu_percent: 1.0, memory_mb: 1}}, old)
      Metrics.record_envs(box.id, %{env => %{slug: "x-1", cpu_percent: 1.0, memory_mb: 1}}, @now)

      assert {1, 1} = Metrics.prune(@now)
      assert %{points: [_]} = Metrics.box_series(box.id, "7d", @now)
    end

    test "runs from an Oban job" do
      assert :ok = Foreman.Jobs.PruneMetrics.perform(%Oban.Job{args: %{}})
    end
  end
end
