defmodule ForemanWeb.CapacityBarTest do
  use ForemanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ForemanWeb.ForemanComponents

  defp bar_class(value, threshold) do
    render_component(&ForemanComponents.capacity_bar/1,
      label: "CPU",
      value: value,
      max: 10,
      threshold: threshold
    )
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("progress")
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split()
  end

  test "under a threshold below 100%: amber past it, red past 100%" do
    assert bar_class(8, 0.9) == ["bar"]
    assert bar_class(9.5, 0.9) == ["bar", "bar-warning"]
    assert bar_class(11, 0.9) == ["bar", "bar-danger"]
  end

  test "under a threshold past 100%: amber past 100%, red past the threshold" do
    assert bar_class(9.5, 4.0) == ["bar"]
    assert bar_class(20, 4.0) == ["bar", "bar-warning"]
    assert bar_class(41, 4.0) == ["bar", "bar-danger"]
  end
end
