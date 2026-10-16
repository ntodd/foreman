defmodule Foreman.GitHubTokensAndSyncTest do
  # Token lifetimes, refresh durability, and repo sync when GitHub
  # misbehaves. Each of these used to cost someone their git push, their
  # login or their repo settings.
  use Foreman.DataCase

  import Mox

  alias Foreman.{Accounts, GitHub}
  alias Foreman.GitHub.ClientMock
  alias Foreman.Repos.Repo, as: GitRepo

  setup :verify_on_exit!

  setup do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:foreman, :github_app) end)
  end

  defp new_tokens(access, refresh) do
    {:ok,
     %{
       access_token: access,
       refresh_token: refresh,
       expires_in: 28_800,
       refresh_token_expires_in: 15_000_000
     }}
  end

  defp expiring_in(seconds), do: DateTime.add(DateTime.utc_now(), seconds)

  describe "environment tokens" do
    test "outlive the next scheduled push" do
      user = user_fixture(access_token: "ghu_short", access_token_expires_at: expiring_in(3600))
      repo = repo_fixture(token_mode: "broad")

      expect(ClientMock, :refresh_user_token, fn _, _ -> new_tokens("ghu_long", "ghr_2") end)

      assert {:ok, "ghu_long"} = GitHub.environment_token(user, repo)
    end

    test "reuse the user's token while it has hours left" do
      user = user_fixture(access_token: "ghu_ok", access_token_expires_at: expiring_in(6 * 3600))
      repo = repo_fixture(token_mode: "broad")

      assert {:ok, "ghu_ok"} = GitHub.environment_token(user, repo)
    end

    test "a plain user token still only refreshes near expiry" do
      user = user_fixture(access_token: "ghu_ok", access_token_expires_at: expiring_in(3600))
      assert {:ok, "ghu_ok"} = GitHub.user_token(user)
    end

    test "the refresh job pushes to environments whose user's token has expired" do
      user = user_fixture(access_token: "ghu_x", access_token_expires_at: expiring_in(-54 * 60))
      env = environment_fixture(user: user, repo: repo_fixture(token_mode: "broad"))

      env
      |> Ecto.Changeset.change(token_pushed_at: expiring_in(-3600))
      |> Repo.update!()

      :ok = Foreman.Jobs.RefreshTokens.perform(%Oban.Job{args: %{}})

      assert Repo.exists?(
               from o in Foreman.Operations.Operation,
                 where:
                   o.environment_id == ^env.id and o.action == "secrets_write" and
                     o.status == "queued"
             )
    end
  end

  describe "refreshing" do
    test "finishes and stores the rotated token even if the caller dies" do
      user =
        user_fixture(
          access_token: "ghu_old",
          refresh_token: "ghr_old",
          access_token_expires_at: expiring_in(60)
        )

      test_pid = self()

      stub(ClientMock, :refresh_user_token, fn _, "ghr_old" ->
        send(test_pid, :spent)
        Process.sleep(100)
        new_tokens("ghu_new", "ghr_new")
      end)

      caller = spawn(fn -> GitHub.user_token(user) end)
      Mox.allow(ClientMock, test_pid, caller)
      assert_receive :spent, 1000
      Process.exit(caller, :kill)

      assert eventually(fn -> Repo.reload!(user).refresh_token == "ghr_new" end)
    end

    test "a rejected refresh doesn't wipe tokens from a sign-in that happened meanwhile" do
      user = user_fixture(refresh_token: "ghr_old", access_token_expires_at: expiring_in(60))
      stale = Repo.reload!(user)

      {:ok, _} =
        Accounts.update_tokens(user, %{access_token: "ghu_signin", refresh_token: "ghr_signin"})

      assert :stale = Accounts.mark_github_login_expired(stale)

      reloaded = Repo.reload!(user)
      assert reloaded.refresh_token == "ghr_signin"
      refute reloaded.github_login_expired
    end
  end

  describe "repo sync" do
    defp installation(repos, opts \\ []) do
      expect(ClientMock, :list_installations, fn _ ->
        {:ok, [%{"id" => 77, "account" => %{"login" => "acme", "type" => "User", "id" => 9}}]}
      end)

      expect(ClientMock, :installation_token, fn _, 77 -> {:ok, "ghs_install"} end)
      expect(ClientMock, :list_installation_repos, fn _ -> {:ok, repos} end)
      stub(ClientMock, :list_dir, opts[:list_dir] || fn _, _, _ -> {:error, :not_found} end)

      stub(
        ClientMock,
        :get_file,
        opts[:get_file] ||
          fn _, _, ".devcontainer/devcontainer.json", _ ->
            {:ok, ~s({"dockerComposeFile": "x"})}
          end
      )
    end

    defp gh_repo(id, name),
      do: %{
        "full_name" => "acme/#{name}",
        "name" => name,
        "id" => id,
        "default_branch" => "main",
        "private" => true,
        "archived" => false
      }

    defp synced_repo(id, name) do
      owner =
        Foreman.Repos.get_owner_by_login("acme") ||
          owner_fixture(login: "acme", installation_id: 77)

      repo = repo_fixture(owner: owner, name: name, token_mode: "broad")
      Repo.update!(Ecto.Changeset.change(repo, github_id: id))
    end

    test "a GitHub error while reading the devcontainer keeps what was known" do
      repo = synced_repo(1, "storefront")

      installation([gh_repo(1, "storefront")],
        get_file: fn _, _, _, _ -> {:error, {:http, 403, "API rate limit exceeded"}} end
      )

      {:ok, _} = GitHub.sync_repos()
      assert Repo.reload!(repo).devcontainer_path == ".devcontainer/devcontainer.json"
    end

    test "a GitHub error listing .devcontainer keeps what was known" do
      repo = synced_repo(1, "storefront")

      installation([gh_repo(1, "storefront")],
        list_dir: fn _, _, _ -> {:error, {:http, 502, nil}} end,
        get_file: fn _, _, _, _ -> {:error, :not_found} end
      )

      {:ok, _} = GitHub.sync_repos()
      assert Repo.reload!(repo).devcontainer_path == ".devcontainer/devcontainer.json"
    end

    test "a repo with no devcontainer is still recorded as having none" do
      repo = synced_repo(1, "storefront")

      installation([gh_repo(1, "storefront")],
        get_file: fn _, _, _, _ -> {:error, :not_found} end
      )

      {:ok, _} = GitHub.sync_repos()
      assert Repo.reload!(repo).devcontainer_path == nil
    end

    # A name freed by a rename or delete can be taken by another repo; that
    # repo mustn't get the first one's row, secrets or settings.
    test "a different repo taking a known repo's name gets a row of its own" do
      old = synced_repo(1, "storefront")
      admin = Foreman.Scope.for_user(user_fixture(role: "admin"))

      {:ok, _} =
        Foreman.Secrets.put_secret(admin, "repo", old, %{
          "name" => "DB_PASSWORD",
          "value" => "old-repo-secret"
        })

      installation([gh_repo(2, "storefront")])
      {:ok, _} = GitHub.sync_repos()

      new = Repo.one!(from r in GitRepo, where: r.github_id == 2)
      refute new.id == old.id
      assert new.full_name == "acme/storefront"
      assert new.token_mode == "scoped"
      assert Repo.reload!(old).removed_at

      env = environment_fixture(repo: new)
      refute Map.has_key?(Foreman.Secrets.resolve(env), "DB_PASSWORD")
    end

    test "a renamed repo keeps its row and settings" do
      repo = synced_repo(1, "storefront")
      installation([gh_repo(1, "shopfront")])

      {:ok, _} = GitHub.sync_repos()

      assert [renamed] = Repo.all(from r in GitRepo, where: r.github_id == 1)
      assert renamed.id == repo.id
      assert renamed.full_name == "acme/shopfront"
      assert renamed.token_mode == "broad"
    end

    test "repos gone from the installation drop out of the list and come back if re-added" do
      kept = synced_repo(1, "storefront")
      gone = synced_repo(2, "legacy")
      installation([gh_repo(1, "storefront")])

      {:ok, _} = GitHub.sync_repos()

      ids = Enum.map(Foreman.Repos.list_repos(), & &1.id)
      assert kept.id in ids
      refute gone.id in ids

      installation([gh_repo(1, "storefront"), gh_repo(2, "legacy")])
      {:ok, _} = GitHub.sync_repos()
      assert gone.id in Enum.map(Foreman.Repos.list_repos(), & &1.id)
    end
  end

  describe "the GitHub client" do
    setup do
      Application.put_env(:foreman, :github_req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      on_exit(fn -> Application.delete_env(:foreman, :github_req_options) end)
    end

    test "refuses to return a truncated repo list" do
      Req.Test.stub(__MODULE__, fn conn ->
        page = String.to_integer(conn.params["page"])

        repos =
          for n <- 1..100, do: %{"id" => page * 1000 + n, "full_name" => "acme/r#{page}-#{n}"}

        Req.Test.json(conn, %{"repositories" => repos})
      end)

      assert {:error, :too_many_pages} =
               Foreman.GitHub.Client.Req.list_installation_repos("ghs_install")
    end

    defp github_org(org_status) do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/user/memberships/orgs/acme" -> conn |> Plug.Conn.send_resp(404, "{}")
          "/orgs/acme" -> conn |> Plug.Conn.send_resp(org_status, ~s({"login":"acme"}))
        end
      end)
    end

    test "a 404 for the membership means not a member when the org exists" do
      github_org(200)
      assert {:ok, false} = Foreman.GitHub.Client.Req.org_membership("ghu_x", "acme")
    end

    test "a 404 for the membership of an org that can't be found isn't an answer" do
      github_org(404)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :org_not_found} =
                   Foreman.GitHub.Client.Req.org_membership("ghu_x", "acme")
        end)

      assert log =~ "FOREMAN_ALLOWED_ORG"
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
