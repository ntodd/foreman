defmodule Foreman.GitHubReqFileTest do
  use ExUnit.Case, async: false

  alias Foreman.GitHub.Client.Req, as: GitHubReq

  setup do
    previous = Application.get_env(:foreman, :github_req_options, [])
    Application.put_env(:foreman, :github_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.put_env(:foreman, :github_req_options, previous) end)
  end

  test "a service installation request contains only approved GitHub IDs and contents read" do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/app/installations/7/access_tokens"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert JSON.decode!(body) == %{
               "repository_ids" => [1001, 1002],
               "permissions" => %{"contents" => "read"}
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, ~s({"token":"scoped"}))
    end)

    assert {:ok, "scoped"} =
             GitHubReq.repo_read_token(
               %{client_id: "fixture", private_key: pem},
               7,
               {:ids, [1001, 1002]}
             )
  end

  test "the raw file client accepts the limit and stops past it" do
    for {size, expected} <- [{256 * 1024, :ok}, {256 * 1024 + 1, :too_large}] do
      body = String.duplicate("x", size)
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
      result = GitHubReq.get_file("fixture", "owner/repo", "devcontainer.json", nil)

      if expected == :ok,
        do: assert(result == {:ok, body}),
        else: assert(result == {:error, :too_large})
    end
  end
end
