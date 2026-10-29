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

  for script <- ["mac.sh", "vm.sh"] do
    test "serves the #{script} launcher with the control plane's URL", %{conn: conn} do
      conn = get(conn, "/agent/#{unquote(script)}")
      body = response(conn, 200)
      assert body =~ ~s(FOREMAN_URL="http://localhost)
      refute body =~ "__FOREMAN_URL__"
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/x-shellscript"
    end
  end

  describe "a Flatcar box's first-boot config" do
    test "comes back for a join token, for the box's architecture", %{conn: conn, token: token} do
      conn = post(conn, ~p"/agent/flatcar/ignition", %{"join_token" => token, "arch" => "arm64"})
      config = json_response(conn, 200)
      assert config["ignition"]["version"] == "3.4.0"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-foreman-box") == ["desktop"]

      paths = Enum.map(config["storage"]["files"], & &1["path"])
      assert Enum.any?(paths, &String.ends_with?(&1, "-arm64.raw"))
    end

    test "takes SSH keys for core", %{conn: conn, token: token} do
      key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore box@mac"

      config =
        conn
        |> post(~p"/agent/flatcar/ignition", %{
          "join_token" => token,
          "arch" => "amd64",
          "ssh_keys" => [key]
        })
        |> json_response(200)

      assert [%{"name" => "core", "sshAuthorizedKeys" => [^key]}] = config["passwd"]["users"]
    end

    test "refuses a bad token, architecture or key", %{conn: conn, token: token} do
      assert post(conn, ~p"/agent/flatcar/ignition", %{
               "join_token" => "fj_nope",
               "arch" => "amd64"
             })
             |> json_response(401)

      assert post(again(conn), ~p"/agent/flatcar/ignition", %{
               "join_token" => token,
               "arch" => "mips"
             })
             |> json_response(400)

      assert post(again(conn), ~p"/agent/flatcar/ignition", %{
               "join_token" => token,
               "arch" => "amd64",
               "ssh_keys" => ["not a key"]
             })
             |> json_response(400)
    end

    test "says so when Tailscale won't mint the box a key", %{conn: conn, token: token} do
      Application.put_env(:foreman, :tailscale, %{
        client_id: "c",
        client_secret: "s",
        tailnet: "-",
        tags: []
      })

      on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)

      Mox.stub(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ ->
        {:error, {:http, 403, "nope"}}
      end)

      body =
        conn
        |> post(~p"/agent/flatcar/ignition", %{"join_token" => token, "arch" => "amd64"})
        |> json_response(502)

      assert body["error"] =~ "Tailscale"
    end

    # The same budget as enrollment: a token is a token.
    test "bad tokens count against the client's enroll attempts", %{conn: conn, public: public} do
      for _ <- 1..10 do
        post(again(conn), ~p"/agent/flatcar/ignition", %{
          "join_token" => "fj_nope",
          "arch" => "amd64"
        })
      end

      assert post(again(conn), ~p"/api/agents/enroll", %{
               "join_token" => "fj_x",
               "public_key" => public
             })
             |> json_response(429)
    end
  end

  @tag :tmp_dir
  test "serves the highest version as latest", %{conn: conn, tmp_dir: tmp} do
    {public, private} = ForemanProtocol.Auth.generate_keypair()
    Application.put_env(:foreman, :agent_release_public_key, Base.encode64(public))
    Application.put_env(:foreman, :agent_release_dir, Path.join(tmp, "releases"))

    on_exit(fn ->
      Application.delete_env(:foreman, :agent_release_public_key)
      Application.delete_env(:foreman, :agent_release_dir)
    end)

    tarball = Path.join(tmp, "agent.tar.gz")
    File.write!(tarball, "release bytes")
    sha = :crypto.hash(:sha256, "release bytes") |> Base.encode16(case: :lower)

    for version <- ["0.10.0", "0.9.0"] do
      sig = ForemanProtocol.Auth.sign_release(version, "linux-amd64", sha, private)
      {:ok, _} = Foreman.Agents.Releases.register(version, "linux-amd64", tarball, sig)
    end

    conn = get(conn, ~p"/agent/releases/latest/linux-amd64")
    assert response(conn, 200) == "release bytes"
    assert get_resp_header(conn, "x-foreman-version") == ["0.10.0"]

    # What the image carries comes first: new boxes install what the boxes
    # already there follow.
    bundle = Path.join(tmp, "bundle")
    File.mkdir_p!(bundle)
    File.write!(Path.join(bundle, "foreman_agent-0.9.0-linux-amd64.tar.gz"), "release bytes")
    Application.put_env(:foreman, :bundled_agent_dir, bundle)
    on_exit(fn -> Application.delete_env(:foreman, :bundled_agent_dir) end)

    assert build_conn()
           |> get(~p"/agent/releases/latest/linux-amd64")
           |> get_resp_header("x-foreman-version") == ["0.9.0"]

    # A release whose tarball is gone (a temp dir cleared by a recreate).
    File.rm!(Foreman.Agents.Releases.get("0.9.0", "linux-amd64").path)

    assert build_conn()
           |> get(~p"/agent/releases/0.9.0/linux-amd64")
           |> json_response(404)
  end

  # A second request from the same client (rate limits are per client).
  defp again(conn), do: %{build_conn() | remote_ip: conn.remote_ip}
end
