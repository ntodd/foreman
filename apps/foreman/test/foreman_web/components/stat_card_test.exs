defmodule ForemanWeb.StatCardTest do
  use ForemanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ForemanWeb.ForemanComponents

  test "shows a labelled value with its breakdown and note" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <ForemanComponents.stat_card id="cores" value_id="cores-value" icon="hero-cpu-chip" label="Cores">
        32
        <:detail>4 provisioned</:detail>
        <:note>On the online boxes</:note>
      </ForemanComponents.stat_card>
      """)
      |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query("#cores") |> LazyHTML.text() =~ "Cores"
    assert html |> LazyHTML.query("#cores-value") |> LazyHTML.text() |> String.trim() == "32"
    assert LazyHTML.text(html) =~ "4 provisioned"
    assert LazyHTML.text(html) =~ "On the online boxes"
  end

  test "leaves out the breakdown and note when there are none" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <ForemanComponents.stat_card icon="hero-cube" label="Environments">3</ForemanComponents.stat_card>
      """)
      |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query("p") |> Enum.count() == 2
  end
end
