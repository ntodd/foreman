defmodule ForemanWeb.BoxChartsEdgeTest do
  @moduledoc """
  What an agent sends when it can't read a total (df failing gives a disk
  total of 0) must not take the box page down.
  """
  use ForemanWeb.ConnCase

  alias Foreman.Metrics
  alias ForemanWeb.BoxCharts
  alias ForemanWeb.Charts.Geometry

  setup :register_and_log_in_admin

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

  test "a stored sample with a disk total of 0 still renders the box page", %{
    conn: conn,
    user: user
  } do
    box = box_fixture(owner_user_id: user.id)
    now = System.system_time(:second)
    Metrics.insert_box!(box.id, sample(now - 10, %{disk_total_mb: 0, disk_used_mb: 0}))

    assert {:ok, _view, html} = live(conn, ~p"/boxes/#{box.id}")
    assert html =~ "disk-chart"
  end

  test "a live sample with a disk total of 0 doesn't crash an open box page", %{
    conn: conn,
    user: user
  } do
    box = box_fixture(owner_user_id: user.id)
    now = System.system_time(:second)
    for i <- 0..5, do: Metrics.insert_box!(box.id, sample(now - 60 + i * 5))

    {:ok, view, _html} = live(conn, ~p"/boxes/#{box.id}")
    Metrics.record_box(box.id, sample(now, %{disk_total_mb: 0, disk_used_mb: 0}))

    assert render(view) =~ "disk-chart"
  end

  test "a memory total of 0 falls back to the box's capacity", %{user: user} do
    box = box_fixture(owner_user_id: user.id, capacity: %{"memory_mb" => 32_768})
    now = System.system_time(:second)
    Metrics.insert_box!(box.id, sample(now - 10, %{memory_total_mb: 0, memory_used_mb: 0}))

    html =
      render_component(&BoxCharts.usage/1,
        box: box,
        series: Metrics.box_series(box.id, "1h", now),
        envs: Metrics.env_series(box.id, "1h", now),
        latest: nil
      )

    assert html =~ "memory-chart"
    assert html =~ "of 32.0 GiB"
  end

  test "Geometry.y puts a value on the baseline when the scale is zero or negative" do
    assert Geometry.y(5, %{ymax: 0}) == 100.0
    assert Geometry.y(5, %{ymax: -1}) == 100.0
  end

  test "Geometry.x puts a point at the left edge when the range is empty" do
    assert Geometry.x(10, %{since: 10, until: 10}) == 0.0
  end
end
