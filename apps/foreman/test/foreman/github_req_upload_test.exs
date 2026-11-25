defmodule Foreman.GitHubReqUploadTest do
  use ExUnit.Case, async: false

  alias Foreman.GitHub.Client.Req, as: GitHubReq

  setup do
    previous = Application.get_env(:foreman, :github_req_options, [])
    Application.put_env(:foreman, :github_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.put_env(:foreman, :github_req_options, previous) end)
  end

  test "an attachment goes to the upload host as its bytes, for one repository" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "uploads.github.com"
      assert conn.request_path == "/user-attachments/assets"

      assert Plug.Conn.fetch_query_params(conn).query_params == %{
               "name" => "login page.png",
               "content_type" => "image/png",
               "repository_id" => "1001"
             }

      assert Plug.Conn.get_req_header(conn, "authorization") == ["token github_pat_bot"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]
      assert {:ok, <<1, 2, 3>>, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        201,
        ~s({"url":"https://github.com/user-attachments/assets/5b8ee541"})
      )
    end)

    assert {:ok, "https://github.com/user-attachments/assets/5b8ee541"} =
             GitHubReq.upload_attachment(
               "github_pat_bot",
               1001,
               "login page.png",
               "image/png",
               <<1, 2, 3>>
             )
  end

  test "a refusal comes back with its status and what GitHub said" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, ~s({"message":"Not Found"}))
    end)

    assert {:error, {:http, 404, "Not Found"}} =
             GitHubReq.upload_attachment("github_pat_bot", 1001, "a.png", "image/png", "x")
  end

  test "an upload GitHub fails is sent once, and never again by itself" do
    # As configured outside tests, where failed requests are retried.
    Application.put_env(:foreman, :github_req_options, plug: {Req.Test, __MODULE__})
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 503, "")
    end)

    assert {:error, {:http, 503, _}} =
             GitHubReq.upload_attachment("github_pat_bot", 1001, "a.png", "image/png", "x")

    assert :counters.get(counter, 1) == 1
  end

  test "an answer with no asset URL to reference is an error" do
    for body <- [
          ~s({"id":7}),
          ~s({"url":""}),
          ~s({"url":7}),
          ~s|{"url":"javascript:alert(1)"}|,
          ~s({"url":"https://"}),
          ~s({"url":"https:///user-attachments/assets/1"}),
          ~s({"url":"http://github.com/user-attachments/assets/1"})
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, body)
      end)

      assert {:error, :no_asset_url} =
               GitHubReq.upload_attachment("github_pat_bot", 1001, "a.png", "image/png", "x")
    end
  end
end
