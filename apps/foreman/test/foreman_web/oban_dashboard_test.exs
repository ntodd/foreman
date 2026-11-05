defmodule ForemanWeb.ObanDashboardTest do
  @moduledoc """
  Oban Web's dashboard. Rendering it needs Oban's plugins, which testing
  mode doesn't run, so these check what the route mounts with.
  """
  use ForemanWeb.ConnCase

  alias Foreman.Scope

  defp live_session do
    %{phoenix_live_view: {_view, _action, _opts, live_session}} =
      Phoenix.Router.route_info(ForemanWeb.Router, "GET", "/admin/oban", "localhost")

    live_session
  end

  # LiveView signs the session it puts in the page; it doesn't encrypt it.
  test "the session Oban Web puts in the page carries no GitHub tokens", %{conn: conn} do
    user = user_fixture(role: "admin", access_token: "gho_SECRET", refresh_token: "ghr_SECRET")
    conn = Plug.Conn.assign(conn, :current_scope, Scope.for_user(user))
    {module, function, args} = live_session().extra.session

    session = apply(module, function, [conn | args])

    assert session["access"] == :all
    refute :erlang.term_to_binary(session) =~ "gho_SECRET"
    refute :erlang.term_to_binary(session) =~ "ghr_SECRET"
  end

  # The session above is fixed when the page renders; a page left open
  # reconnects with it. Foreman's own checks read the user afresh.
  test "every mount checks for a signed-in admin before Oban Web's own check" do
    hooks = Enum.map(live_session().extra.on_mount, & &1.id)

    assert [
             {ForemanWeb.UserAuth, :require_user},
             {ForemanWeb.UserAuth, :require_admin},
             {Oban.Web.Authentication, :default}
           ] = hooks
  end
end
