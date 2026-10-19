defmodule Foreman.EnvironmentsBranchSyncTest do
  # Whether an environment's clone is behind (or ahead of) its branch on
  # GitHub, from the HEAD its agent reports.
  use Foreman.DataCase

  import Mox

  alias Foreman.Environments
  alias Foreman.GitHub.ClientMock

  setup :verify_on_exit!

  @head "1111111111111111111111111111111111111111"
  @base "2222222222222222222222222222222222222222"

  setup do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:foreman, :github_app) end)

    owner = owner_fixture(installation_id: 77)
    repo = repo_fixture(owner: owner, name: "storefront")
    env = environment_fixture(repo: repo, branch: "feature/x")
    %{env: env, repo: repo}
  end

  defp status(attrs) do
    Map.merge(
      %{"branch" => "feature/x", "head" => @head, "base" => @head, "ahead" => 0},
      attrs
    )
  end

  test "compares HEAD with the branch on GitHub", %{env: env, repo: repo} do
    full_name = repo.full_name
    expect(ClientMock, :installation_token, fn _, 77 -> {:ok, "ghs_install"} end)

    expect(ClientMock, :compare, fn "ghs_install", ^full_name, @head, "feature/x" ->
      {:ok, %{ahead_by: 3, behind_by: 0}}
    end)

    assert {:ok, %{behind: 3, ahead: 0}} = Environments.branch_sync(env, status(%{}))
  end

  # The upstream ref is stale and the clone's commit has since been merged
  # on GitHub: HEAD is known there, so its count is exact, whatever git
  # status says about the old upstream.
  test "a HEAD GitHub knows is compared as is", %{env: env} do
    stub(ClientMock, :installation_token, fn _, _ -> {:ok, "ghs_install"} end)
    expect(ClientMock, :compare, fn _, _, @head, _ -> {:ok, %{ahead_by: 1, behind_by: 0}} end)

    assert {:ok, %{behind: 1, ahead: 0}} =
             Environments.branch_sync(env, status(%{"base" => @base, "ahead" => 1}))
  end

  test "commits never pushed fall back to the merge base, counted locally", %{env: env} do
    stub(ClientMock, :installation_token, fn _, _ -> {:ok, "ghs_install"} end)
    expect(ClientMock, :compare, fn _, _, @head, _ -> {:error, :not_found} end)
    expect(ClientMock, :compare, fn _, _, @base, _ -> {:ok, %{ahead_by: 3, behind_by: 0}} end)

    assert {:ok, %{behind: 3, ahead: 2}} =
             Environments.branch_sync(env, status(%{"base" => @base, "ahead" => 2}))
  end

  test "commits the branch lost (a force push) count as the clone's own", %{env: env} do
    stub(ClientMock, :installation_token, fn _, _ -> {:ok, "ghs_install"} end)
    expect(ClientMock, :compare, fn _, _, @head, _ -> {:ok, %{ahead_by: 1, behind_by: 4}} end)

    assert {:ok, %{behind: 1, ahead: 4}} = Environments.branch_sync(env, status(%{}))
  end

  test "without an upstream, HEAD itself is compared", %{env: env} do
    stub(ClientMock, :installation_token, fn _, _ -> {:ok, "ghs_install"} end)
    expect(ClientMock, :compare, fn _, _, @head, _ -> {:ok, %{ahead_by: 0, behind_by: 0}} end)

    assert {:ok, %{behind: 0, ahead: 0}} =
             Environments.branch_sync(env, status(%{"base" => nil}))
  end

  test "a clone on another branch isn't compared", %{env: env} do
    assert {:ok, %{other_branch: "topic"}} =
             Environments.branch_sync(env, status(%{"branch" => "topic"}))
  end

  test "only an object name goes to GitHub", %{env: env} do
    assert {:error, :no_head} =
             Environments.branch_sync(env, status(%{"head" => "../x", "base" => "main"}))
  end

  test "a GitHub error is passed on", %{env: env} do
    stub(ClientMock, :installation_token, fn _, _ -> {:ok, "ghs_install"} end)
    expect(ClientMock, :compare, fn _, _, _, _ -> {:error, :not_found} end)

    assert {:error, :not_found} = Environments.branch_sync(env, status(%{}))
  end

  describe "the GitHub client" do
    setup do
      Application.put_env(:foreman, :github_req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      on_exit(fn -> Application.delete_env(:foreman, :github_req_options) end)
    end

    test "asks for the counts without the commit list" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/repos/acme/storefront/compare/#{@head}...feature/x"
        assert conn.params["per_page"] == "1"
        Req.Test.json(conn, %{"ahead_by" => 3, "behind_by" => 1, "status" => "diverged"})
      end)

      assert {:ok, %{ahead_by: 3, behind_by: 1}} =
               Foreman.GitHub.Client.Req.compare("ghs", "acme/storefront", @head, "feature/x")
    end

    test "a commit GitHub doesn't have is not found" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, :not_found} =
               Foreman.GitHub.Client.Req.compare("ghs", "acme/storefront", @head, "main")
    end
  end
end
