defmodule ForemanWeb.CLIInstallerTest do
  use ForemanWeb.ConnCase

  setup %{conn: conn} do
    previous = Application.get_env(:foreman, :base_url)
    Application.put_env(:foreman, :base_url, "https://foreman.example.org")
    on_exit(fn -> Application.put_env(:foreman, :base_url, previous) end)
    %{conn: %{conn | scheme: :https}}
  end

  test "a member with no grants can copy each instance-specific command", %{conn: conn} do
    html =
      conn
      |> log_in(user_fixture())
      |> get("https://test.invalid/settings/connections")
      |> html_response(200)

    assert html =~ "You have no active connections"
    assert html =~ "Install the CLI"

    doc = LazyHTML.from_document(html)

    for {id, command} <- [
          {"cli-install", "curl -fsSL https://foreman.example.org/cli/install.sh | sh"},
          {"cli-login", "foreman --instance https://foreman.example.org login"}
        ] do
      assert doc |> LazyHTML.query("code##{id}") |> LazyHTML.text() == command

      assert doc |> LazyHTML.query("button##{id}-copy") |> LazyHTML.attribute("data-copy") == [
               command
             ]
    end
  end

  test "anonymous discovery selects the highest complete stable release across all pages", %{
    conn: conn
  } do
    Foreman.CLIReleases.reset_cache()
    on_exit(&Foreman.CLIReleases.reset_cache/0)
    Application.put_env(:foreman, :cli_release_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:foreman, :cli_release_req_options) end)

    Req.Test.stub(__MODULE__, fn req ->
      assert req.host == "api.github.com"
      assert req.request_path == "/repos/ntodd/foreman/releases"
      assert get_req_header(req, "authorization") == []
      assert get_req_header(req, "cookie") == []

      if fetch_query_params(req).query_params["page"] == "2" do
        Req.Test.json(req, [release("v1.10.0")])
      else
        req
        |> put_resp_header(
          "link",
          ~s(<https://api.github.com/repositories/123/releases?page=2>; rel="next")
        )
        |> Req.Test.json([
          release("v1.9.0"),
          Map.put(release("v2.0.0"), :draft, true),
          Map.put(release("v2.0.1"), :prerelease, true),
          release("v2.1.0-rc.1"),
          release("v03.1.0"),
          Map.update!(release("v3.0.0"), :assets, &tl/1),
          Map.update!(release("v4.0.0"), :assets, &Enum.drop(&1, -1))
        ])
      end
    end)

    assert conn |> get("https://test.invalid/cli/release") |> response(200) == "v1.10.0\n"

    Req.Test.stub(__MODULE__, &send_resp(&1, 429, "rate limited"))
    assert conn |> get("https://test.invalid/cli/release") |> response(200) == "v1.10.0\n"

    Foreman.CLIReleases.reset_cache()
    assert conn |> get("https://test.invalid/cli/release") |> response(503) =~ "try again"
  end

  defp release(tag) do
    names = for os <- ~w(linux darwin), arch <- ~w(arm64 amd64), do: "#{os}-#{arch}.tar.gz"

    assets =
      for name <- names ++ ["SHA256SUMS"],
          do: %{name: "foreman-cli-#{tag}-#{name}", state: "uploaded"}

    %{tag_name: tag, assets: assets, draft: false, prerelease: false, published_at: "2026-01-01"}
  end

  test "the anonymous HTTPS installer can be piped to sh", %{conn: conn} do
    resp = get(conn, "https://test.invalid/cli/install.sh")
    assert [content_type] = get_resp_header(resp, "content-type")
    assert content_type =~ "text/x-shellscript"
    assert response(resp, 200) =~ "https://foreman.example.org/cli/release"
    assert resp.resp_body =~ "#!/bin/sh"
    assert get(%{conn | scheme: :http}, "/cli/install.sh").status == 400
  end
end
