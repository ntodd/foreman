defmodule ForemanWeb.CapacityBarTest do
  use ForemanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ForemanWeb.ForemanComponents

  defp bar(value, threshold, opts \\ []) do
    render_component(
      &ForemanComponents.capacity_bar/1,
      [label: "CPU", value: value, max: 10, threshold: threshold] ++ opts
    )
    |> LazyHTML.from_fragment()
  end

  defp bar_class(value, threshold, opts \\ []) do
    bar(value, threshold, opts)
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

  describe "with usage drawn in the same bar" do
    test "draws the larger of the two" do
      html = bar(4, 0.9, used: 7)
      assert LazyHTML.text(html) =~ "7 / 10"
      assert html |> LazyHTML.query("progress") |> LazyHTML.attribute("value") == ["700"]

      assert LazyHTML.text(bar(7, 0.9, used: 4)) =~ "7 / 10"
    end

    test "busy usage colors a bar whose provisioned total is within its threshold" do
      # 10 of 10 provisioned is fine at 4x; 9.5 of 10 in use is past 90%.
      assert bar_class(10, 4.0, used: 9.5) == ["bar", "bar-warning"]
      assert bar_class(10, 4.0, used: 9.5) == bar_class(9.5, 4.0, used: 9.5)
    end

    test "usage past 90% doesn't turn allowed overcommit red" do
      assert bar_class(20, 4.0, used: 9.5) == ["bar", "bar-warning"]
    end

    test "the more severe of the two wins" do
      assert bar_class(41, 4.0, used: 9.5) == ["bar", "bar-danger"]
      assert bar_class(5, 4.0, used: 2) == ["bar"]
    end

    test "zero usage is still usage" do
      assert bar_class(9.5, 0.9, used: 0) == ["bar", "bar-warning"]
      assert bar_class(5, 4.0, used: 0) == ["bar"]
    end
  end
end
