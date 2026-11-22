defmodule Foreman.GitHubReqFileTest do
  use ExUnit.Case, async: false

  alias Foreman.GitHub.Client.Req, as: GitHubReq

  setup do
    previous = Application.get_env(:foreman, :github_req_options, [])
    Application.put_env(:foreman, :github_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.put_env(:foreman, :github_req_options, previous) end)
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
