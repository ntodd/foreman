defmodule ForemanWeb.AgentControllerTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Boxes, Repo, Scope}

  setup do
    admin = user_fixture(role: "admin")
    {:ok, token} = Boxes.create_join_token(Scope.for_user(admin), %{"box_name" => "desktop"})
    {public, _private} = ForemanProtocol.Auth.generate_keypair()
    %{token: token, public: Base.encode64(public), admin: admin}
  end

  test "enrolls an agent once per join token", %{conn: conn, token: token, public: public} do
    conn =
      post(conn, ~p"/api/agents/enroll", %{
        "join_token" => token,
        "public_key" => public,
        "hostname" => "mona-desktop"
      })

    assert %{"agent_id" => id, "box" => "desktop"} = json_response(conn, 201)
    assert Repo.get!(Foreman.Boxes.Box, id).hostname == "mona-desktop"

    again =
      post(again(conn), ~p"/api/agents/enroll", %{"join_token" => token, "public_key" => public})

    assert json_response(again, 401)["error"] =~ "used"
  end

  test "refuses bad tokens and keys", %{conn: conn, token: token} do
    assert post(conn, ~p"/api/agents/enroll", %{"join_token" => "fj_nope", "public_key" => "x"})
           |> json_response(401)

    assert post(again(conn), ~p"/api/agents/enroll", %{
             "join_token" => token,
             "public_key" => "short"
           })
           |> json_response(400)
  end

  test "an expired join token is refused", %{conn: conn, token: token, public: public} do
    Repo.update_all(Foreman.Boxes.JoinToken,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert post(conn, ~p"/api/agents/enroll", %{"join_token" => token, "public_key" => public})
           |> json_response(401)
  end

  test "only admins create join tokens" do
    member = user_fixture()

    assert {:error, :unauthorized} =
             Boxes.create_join_token(Scope.for_user(member), %{"box_name" => "x"})
  end

  test "serves the install script with the control plane's URL", %{conn: conn} do
    body = conn |> get(~p"/agent/install.sh") |> response(200)
    assert body =~ "FOREMAN_URL=\"http://localhost"
    refute body =~ "__FOREMAN_URL__"
  end

  # A second request from the same client (rate limits are per client).
  defp again(conn), do: %{build_conn() | remote_ip: conn.remote_ip}
end
