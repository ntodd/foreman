defmodule ForemanWeb.ErrorJSONTest do
  use ForemanWeb.ConnCase, async: true

  test "resource API framework errors include the public code and a safe message" do
    conn = build_conn(:get, "/api/v1/me")

    assert ForemanWeb.ErrorJSON.render("500.json", %{conn: conn}) ==
             %{code: "internal_error", message: "Internal Server Error"}

    assert ForemanWeb.ErrorJSON.render("406.json", %{conn: conn}) ==
             %{code: "not_acceptable", message: "Not Acceptable"}

    assert ForemanWeb.ErrorJSON.render("404.json", %{conn: conn}) ==
             %{code: "resource_not_found", message: "Not Found"}
  end

  test "renders 404" do
    assert ForemanWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert ForemanWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
