defmodule ForemanWeb.BoxMetricsTest do
  use ForemanWeb.ConnCase

  alias Foreman.Metrics

  setup :register_and_log_in_admin

  setup %{user: user} do
    box =
      box_fixture(
        owner_user_id: user.id,
        name: "desktop",
        capacity: %{
          "cpus" => 4,
          "memory_mb" => 16_384,
          "disk_mb" => 100_000,
          "disk_free_mb" => 40_000
        }
      )

    %{box: box}
  end

  defp sample(at, attrs \\ %{}) do
    Map.merge(
      %{
        at: at,
        cpu_percent: 37.0,
        load1: 1.25,
        memory_total_mb: 16_384,
        memory_used_mb: 6_144,
        swap_total_mb: 0,
        swap_used_mb: 0,
        disk_total_mb: 100_000,
        disk_used_mb: 60_000
      },
      attrs
    )
  end

  test "the box page charts CPU, memory, disk and load", %{conn: conn, box: box} do
    now = System.system_time(:second)
    for i <- 0..11, do: Metrics.insert_box!(box.id, sample(now - 60 + i * 5))

    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")

    for id <- ~w(cpu-chart memory-chart disk-chart load-chart),
        do: assert(has_element?(view, "##{id}"))

    assert has_element?(view, "#cpu-chart .chart-value", "37%")
    assert has_element?(view, "#memory-chart .chart-value", "6.0 GiB")
    assert has_element?(view, "#load-chart", "4 cores")
  end

  test "the range picker patches the URL and redraws", %{conn: conn, box: box} do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
    assert has_element?(view, ~s|#range-picker a[aria-current="true"]|, "1h")

    view |> element("#range-picker a", "7d") |> render_click()
    assert_patch(view, ~p"/boxes/#{box.id}?range=7d")
    assert has_element?(view, ~s|#range-picker a[aria-current="true"]|, "7d")
  end

  test "live samples update the headline", %{conn: conn, box: box} do
    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
    assert has_element?(view, "#cpu-chart", "No samples")

    Metrics.record_box(box.id, sample(System.system_time(:second), %{cpu_percent: 81.0}))
    assert render(view) =~ "81%"
  end

  test "environments stack under the box's totals", %{conn: conn, box: box, user: user} do
    env = environment_fixture(box: box, user: user)
    now = System.system_time(:second)

    Metrics.record_envs(
      box.id,
      %{env.id => %{slug: env.slug, cpu_percent: 200.0, memory_mb: 2_048}},
      now - 30
    )

    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
    # 200% of one core on a 4-core box is half the box.
    assert has_element?(view, "#cpu-chart li", env.slug)
    assert has_element?(view, "#cpu-chart li", "50%")
    assert has_element?(view, "#memory-chart li", "2.0 GiB")
  end

  test "the boxes list shows live CPU and memory trends", %{conn: conn, box: box} do
    now = System.system_time(:second)
    for i <- 0..5, do: Metrics.insert_box!(box.id, sample(now - 30 + i * 5))

    {:ok, view, _html} = live(conn, ~p"/boxes")
    assert has_element?(view, "#box-#{box.id} [data-metric=cpu]", "37%")
    assert has_element?(view, "#box-#{box.id} [data-metric=memory]", "6.0 of 16.0 GiB")
  end
end
