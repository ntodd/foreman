defmodule ForemanAgent.IdentityTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, Identity}

  @moduletag :tmp_dir

  test "enrolls with a join token and saves the identity privately", %{tmp_dir: tmp} do
    test_pid = self()

    Req.Test.stub(Identity, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:enroll, conn.request_path, JSON.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, JSON.encode!(%{"agent_id" => "agent-123"}))
    end)

    config = %Config{
      url: "https://foreman.example/",
      data_dir: Path.join(tmp, "data"),
      join_token: "jt_abc"
    }

    assert {:ok, %Identity{agent_id: "agent-123"} = identity} =
             Identity.enroll(config, req_options: [plug: {Req.Test, Identity}])

    assert_receive {:enroll, "/api/agents/enroll", body}
    assert body["join_token"] == "jt_abc"
    assert {:ok, public} = Base.decode64(body["public_key"])
    assert public == ForemanProtocol.Auth.public_key(identity.private_key)

    assert {:ok, ^identity} = Identity.load(config.data_dir)
    {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(config.data_dir, "identity.json"))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "reports a refused join token", %{tmp_dir: tmp} do
    Req.Test.stub(Identity, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, JSON.encode!(%{"error" => "join token is invalid or used"}))
    end)

    config = %Config{
      url: "https://foreman.example",
      data_dir: Path.join(tmp, "data"),
      join_token: "bad"
    }

    assert {:error, message} = Identity.enroll(config, req_options: [plug: {Req.Test, Identity}])
    assert message =~ "invalid or used"
    assert Identity.load(config.data_dir) == :none
  end
end
