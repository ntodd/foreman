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

    expect(ClientMock, :check_token, fn "ghp_x" ->
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

  test "an admin sets the extra repos every one of an owner's repos' tokens reach",
       %{conn: conn} do
    owner = owner_fixture(login: "acme")

    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("#owner-#{owner.id} button[phx-click=edit_extra_repos]") |> render_click()

    html =
      view
      |> form("#extra-repos-form", extra_repos: %{repos: "shared-config, design-system"})
      |> render_submit()

    assert Foreman.Repo.reload!(owner).extra_repos == ["shared-config", "design-system"]
    assert html =~ "shared-config, design-system"
    refute has_element?(view, "#extra-repos-form")
  end

  test "extra repos that aren't repo names aren't saved, and the form says why", %{conn: conn} do
    owner = owner_fixture(login: "acme")

    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> element("#owner-#{owner.id} button[phx-click=edit_extra_repos]") |> render_click()

    html =
      view
      |> form("#extra-repos-form", extra_repos: %{repos: "globex/config"})
      |> render_submit()

    assert html =~ "repo names under acme"
    assert has_element?(view, "#extra-repos-form")
    assert Foreman.Repo.reload!(owner).extra_repos == []
  end

  describe "the attachment token" do
    test "an admin adds one, and the page says whose it is and when it lapses", %{conn: conn} do
      owner = owner_fixture(login: "acme")

      expect(ClientMock, :check_token, fn "github_pat_bot" ->
        {:ok, %{login: "acme-bot", scopes: [], expires_at: ~U[2027-11-25 00:00:00.000000Z]}}
      end)

      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "Attachment token"
      view |> element("#owner-#{owner.id} button[phx-click=edit_attachment]") |> render_click()

      view
      |> form("#attachment-form", attachment: %{token: "github_pat_bot"})
      |> render_submit()

      html = render_async(view)
      assert html =~ "acme-bot"
      assert html =~ "expires Nov 25, 2027"
      refute html =~ "github_pat_bot"
      refute has_element?(view, "#attachment-form")

      owner = Foreman.Repo.reload!(owner)
      assert owner.attachment_token == "github_pat_bot"
      assert owner.attachment_login == "acme-bot"
    end

    test "one GitHub won't take isn't saved, and the page says why", %{conn: conn} do
      owner = owner_fixture(login: "acme")
      expect(ClientMock, :check_token, fn _ -> {:error, :invalid_token} end)

      {:ok, view, _html} = live(conn, ~p"/admin")
      view |> element("#owner-#{owner.id} button[phx-click=edit_attachment]") |> render_click()

      view
      |> form("#attachment-form", attachment: %{token: "github_pat_revoked"})
      |> render_submit()

      assert render_async(view) =~ "Not saved: GitHub rejected the token"
      assert has_element?(view, "#attachment-form")
      assert Foreman.Repo.reload!(owner).attachment_token == nil
    end

    test "a check under way can't be cancelled out from under its save", %{conn: conn} do
      owner =
        owner_fixture(login: "acme")
        |> Ecto.Changeset.change(attachment_token: "github_pat_old", attachment_login: "old-bot")
        |> Foreman.Repo.update!()

      other = owner_fixture(login: "globex")
      test = self()

      # GitHub takes its time.
      expect(ClientMock, :check_token, fn _ ->
        send(test, {:checking, self()})

        receive do
          :answer -> {:ok, %{login: "acme-bot", scopes: [], expires_at: nil}}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/admin")
      view |> element("#owner-#{owner.id} button[phx-click=edit_attachment]") |> render_click()
      view |> form("#attachment-form", attachment: %{token: "github_pat_bot"}) |> render_submit()
      assert_receive {:checking, checker}, 1_000

      # Cancelling now would leave a save on its way that nothing shows:
      # a Remove made meanwhile would be undone by it.
      assert has_element?(view, "#attachment-form button[phx-click=cancel_attachment][disabled]")
      render_hook(view, "cancel_attachment", %{})
      assert has_element?(view, "#attachment-form")

      # Nor by opening another owner's form, which would put this owner's
      # Remove back on the page, nor by a Remove sent some other way.
      render_hook(view, "edit_attachment", %{"id" => other.id})
      assert has_element?(view, "#owner-#{owner.id} #attachment-form")
      refute has_element?(view, "button[phx-click=remove_attachment]:not([disabled])")
      render_hook(view, "remove_attachment", %{"id" => owner.id})
      assert Foreman.Repo.reload!(owner).attachment_token == "github_pat_old"

      # Nor does a second check start beside it, of either kind: the first
      # to finish would say nothing is being checked any more.
      render_hook(view, "edit_registry", %{"id" => owner.id})
      refute has_element?(view, "#registry-form")

      render_hook(view, "save_registry", %{
        "registry" => %{"host" => "ghcr.io", "username" => "bot", "token" => "ghp_x"}
      })

      render_hook(view, "save_attachment", %{"attachment" => %{"token" => "github_pat_other"}})
      assert has_element?(view, "#owner-#{owner.id} #attachment-form")

      send(checker, :answer)
      assert render_async(view) =~ "acme-bot"
      assert Foreman.Repo.reload!(owner).attachment_token == "github_pat_bot"
    end

    test "saving nothing leaves the token that was there", %{conn: conn} do
      owner =
        owner_fixture(login: "acme")
        |> Ecto.Changeset.change(attachment_token: "github_pat_bot", attachment_login: "acme-bot")
        |> Foreman.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/admin")
      view |> element("#owner-#{owner.id} button[phx-click=edit_attachment]") |> render_click()

      # The form to replace a token opens empty.
      html = view |> form("#attachment-form", attachment: %{token: "  "}) |> render_submit()

      assert html =~ "Paste a token"
      assert has_element?(view, "#attachment-form")
      assert Foreman.Repo.reload!(owner).attachment_token == "github_pat_bot"
    end

    test "an admin removes it", %{conn: conn} do
      owner =
        owner_fixture(login: "acme")
        |> Ecto.Changeset.change(attachment_token: "github_pat_bot", attachment_login: "acme-bot")
        |> Foreman.Repo.update!()

      {:ok, view, html} = live(conn, ~p"/admin")
      assert html =~ "acme-bot"

      html =
        view
        |> element("#owner-#{owner.id} button[phx-click=remove_attachment]")
        |> render_click()

      refute html =~ "acme-bot"
      assert Foreman.Repo.reload!(owner).attachment_token == nil
      refute has_element?(view, "#owner-#{owner.id} button[phx-click=remove_attachment]")
    end
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
