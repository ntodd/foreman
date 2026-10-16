defmodule ForemanWeb.RateLimitTest do
  @moduledoc """
  The documented deployment puts the control plane on 127.0.0.1 behind
  `tailscale serve`, so every request arrives from the same peer
  address. Rate limits must not turn into one bucket for everybody, and
  junk mustn't lock out correctly signed agents.
  """
  use ForemanWeb.ConnCase

  require Phoenix.ChannelTest, as: ChannelTest

  alias ForemanProtocol.Auth
  alias ForemanWeb.AgentSocket

  @endpoint ForemanWeb.Endpoint
  @proxy {127, 0, 0, 1}

  # A fresh tailnet address per test, so buckets don't leak between tests.
  defp client, do: "100.64.#{:rand.uniform(250)}.#{:rand.uniform(250)}"

  defp signed(box, peer, forwarded) do
    %{
      x_headers: Enum.to_list(Auth.connect_headers(box.id, box.__private_key__)) ++ forwarded,
      peer_data: %{address: peer, port: 1, ssl_cert: nil}
    }
  end

  defp junk(peer, forwarded) do
    %{x_headers: forwarded, peer_data: %{address: peer, port: 1, ssl_cert: nil}}
  end

  describe "agent connects" do
    test "junk from behind the proxy doesn't lock out a signed agent" do
      box = box_fixture()
      attacker = [{"x-forwarded-for", client()}]
      agent = [{"x-forwarded-for", client()}]

      for _ <- 1..200,
          do: :error = ChannelTest.connect(AgentSocket, %{}, connect_info: junk(@proxy, attacker))

      assert {:ok, _} =
               ChannelTest.connect(AgentSocket, %{}, connect_info: signed(box, @proxy, agent))
    end

    test "junk from the agent's own address doesn't lock it out either" do
      box = box_fixture()
      peer = {10, 77, :rand.uniform(250), :rand.uniform(250)}

      for _ <- 1..60,
          do: :error = ChannelTest.connect(AgentSocket, %{}, connect_info: junk(peer, []))

      assert {:ok, _} = ChannelTest.connect(AgentSocket, %{}, connect_info: signed(box, peer, []))
    end

    test "successful connects don't count against the limit" do
      box = box_fixture()
      peer = {10, 78, :rand.uniform(250), :rand.uniform(250)}

      for _ <- 1..100 do
        assert {:ok, _} =
                 ChannelTest.connect(AgentSocket, %{}, connect_info: signed(box, peer, []))
      end
    end

    test "a flood of failures from one client is cut off before verification" do
      peer = {10, 79, :rand.uniform(250), :rand.uniform(250)}

      for _ <- 1..600,
          do: :error = ChannelTest.connect(AgentSocket, %{}, connect_info: junk(peer, []))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :error = ChannelTest.connect(AgentSocket, %{}, connect_info: junk(peer, []))
        end)

      assert log =~ "rate limited"
    end
  end

  describe "sign-in" do
    setup do
      Application.put_env(:foreman, :github_app, %{
        app_id: "1",
        client_id: "Iv1.abc",
        client_secret: "s",
        private_key: "k"
      })

      on_exit(fn -> Application.delete_env(:foreman, :github_app) end)
    end

    defp callback(conn, forwarded) do
      conn = conn |> put_req_header("x-forwarded-for", forwarded) |> get(~p"/auth/github")
      state = get_session(conn, :oauth_state)

      conn
      |> recycle()
      |> put_req_header("x-forwarded-for", forwarded)
      |> get(~p"/auth/github/callback", %{"code" => "c", "state" => state})
    end

    test "is limited per client behind the proxy, not for everyone at once", %{conn: conn} do
      Mox.stub(Foreman.GitHub.ClientMock, :exchange_code, fn _, _, _, _ -> {:error, :bad} end)
      busy = client()

      for _ <- 1..20, do: callback(conn, busy)
      assert Phoenix.Flash.get(callback(conn, busy).assigns.flash, :error) =~ "Too many"

      refute Phoenix.Flash.get(callback(build_conn(), client()).assigns.flash, :error) =~
               "Too many"
    end

    test "a state that isn't a string is refused, not a crash", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")

      conn =
        conn
        |> recycle()
        |> get("/auth/github/callback?code=c&state[]=x")

      assert redirected_to(conn) == "/sign-in"
    end
  end

  describe "enrollment" do
    test "bad join tokens from one client don't block another" do
      busy = client()

      for _ <- 1..10 do
        build_conn()
        |> put_req_header("x-forwarded-for", busy)
        |> post(~p"/api/agents/enroll", %{"join_token" => "fj_nope"})
      end

      denied =
        build_conn()
        |> put_req_header("x-forwarded-for", busy)
        |> post(~p"/api/agents/enroll", %{"join_token" => "fj_nope"})

      assert denied.status == 429

      other =
        build_conn()
        |> put_req_header("x-forwarded-for", client())
        |> post(~p"/api/agents/enroll", %{"join_token" => "fj_nope"})

      assert other.status == 401
    end
  end
end
