defmodule ForemanWeb.DeploymentTest do
  use ForemanWeb.ConnCase

  import Mox

  alias Foreman.GitHub.ClientMock

  setup :register_and_log_in_admin
  # The credential check runs in a task.
  setup :set_mox_global
  setup :verify_on_exit!

  test "a credential the owner can't store says why instead of crashing the page", %{conn: conn} do
    owner = owner_fixture(login: "acme")

    expect(ClientMock, :check_classic_token, fn "ghp_x" ->
      {:ok, %{login: "bot", scopes: ["read:packages"], expires_at: nil}}
    end)

    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("#owner-#{owner.id} button[phx-click=edit_registry]") |> render_click()

    view
    |> form("#registry-form",
      registry: %{host: "ghcr.io", username: "bot@acme.dev", token: "ghp_x"}
    )
    |> render_submit()

    html = render_async(view)
    assert html =~ "Not saved"
    assert html =~ "username"
    assert Foreman.Repo.reload!(owner).registry_token == nil
  end

  test "each owner's secrets form has its own input ids", %{conn: conn} do
    owner_fixture(login: "acme")
    owner_fixture(login: "globex")

    {:ok, _view, html} = live(conn, ~p"/admin")

    ids =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("[id]")
      |> LazyHTML.attribute("id")

    assert ids -- Enum.uniq(ids) == []
  end
end
