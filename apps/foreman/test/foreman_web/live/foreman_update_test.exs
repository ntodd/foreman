defmodule ForemanWeb.ForemanUpdateTest do
  @moduledoc "A newer Foreman release, and updating to it from the Deployment page."
  # The latest release is cached globally, and the update directory is
  # app config.
  use ForemanWeb.ConnCase, async: false

  alias Foreman.Updates

  setup :register_and_log_in_admin

  setup do
    Application.put_env(:foreman, :updates_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    dir = Path.join(System.tmp_dir!(), "foreman-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "request"))
    File.mkdir_p!(Path.join(dir, "status"))
    Application.put_env(:foreman, :update_dir, dir)
    Updates.reset()

    on_exit(fn ->
      Application.delete_env(:foreman, :updates_req_options)
      Application.delete_env(:foreman, :update_dir)
      Updates.reset()
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp released(version) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [
        %{
          "tag_name" => "v#{version}",
          "html_url" => "https://github.com/ntodd/foreman/releases/tag/v#{version}",
          "draft" => false,
          "prerelease" => false
        }
      ])
    end)

    {:ok, _} = Updates.check()
  end

  defp install_updater(dir, state \\ nil) do
    File.write!(Path.join(dir, "status/updater"), "1\n")

    if state do
      state = Map.put_new(state, "at", DateTime.to_iso8601(DateTime.utc_now()))
      File.write!(Path.join(dir, "status/state.json"), JSON.encode!(state))
    end
  end

  test "says when it's up to date", %{conn: conn} do
    released(Foreman.Config.version())
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#foreman-update", "Up to date")
    refute has_element?(view, "#update-foreman")
  end

  test "a newer release without the host's updater says how to install it", %{conn: conn} do
    released("0.4.7")
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#foreman-update", "Foreman 0.4.7 is available")
    assert has_element?(view, "#foreman-update a[href$='/releases/tag/v0.4.7']")
    assert has_element?(view, "#install-updater", "foreman-update")
    refute has_element?(view, "#update-foreman")
  end

  test "updates from the page when the updater is installed", %{conn: conn, dir: dir} do
    released("0.4.7")
    install_updater(dir)
    {:ok, view, _html} = live(conn, ~p"/admin")

    view |> element("#update-foreman") |> render_click()

    assert File.read!(Path.join(dir, "request/version")) == "0.4.7\n"
    assert has_element?(view, "#foreman-update", "Waiting for the host")
    refute has_element?(view, "#update-foreman")
  end

  test "follows the updater's progress", %{conn: conn, dir: dir} do
    released("0.4.7")

    install_updater(dir, %{
      "state" => "running",
      "to" => "0.4.7",
      "message" => "Pulling ghcr.io/ntodd/foreman:0.4.7."
    })

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#foreman-update", "Pulling ghcr.io/ntodd/foreman:0.4.7.")
    refute has_element?(view, "#update-foreman")

    install_updater(dir, %{
      "state" => "rolled_back",
      "from" => "0.4.6",
      "to" => "0.4.7",
      "message" => "0.4.7 didn't come up healthy, so 0.4.6 is back."
    })

    send(view.pid, :refresh_update)

    assert has_element?(
             view,
             "#foreman-update",
             "0.4.7 didn't come up healthy, so 0.4.6 is back."
           )

    assert has_element?(view, "#update-foreman")
  end

  test "checks again on request", %{conn: conn} do
    released(Foreman.Config.version())
    {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#foreman-update", "Up to date")

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [
        %{"tag_name" => "v0.4.8", "html_url" => "u", "draft" => false, "prerelease" => false}
      ])
    end)

    view |> element("#check-for-updates") |> render_click()
    assert render_async(view) =~ "Foreman 0.4.8 is available"
  end

  test "admins see a newer release on every page", %{conn: conn} do
    released("0.4.7")
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#update-available a[href='/admin']", "0.4.7")
  end

  test "members don't", %{conn: conn} do
    released("0.4.7")
    member = Foreman.Fixtures.user_fixture()
    {:ok, view, _html} = live(log_in(conn, member), ~p"/")
    refute has_element?(view, "#update-available")
  end
end
