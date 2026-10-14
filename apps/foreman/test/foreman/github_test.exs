defmodule Foreman.GitHubTest do
  use Foreman.DataCase

  import Mox

  alias Foreman.GitHub
  alias Foreman.GitHub.ClientMock

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

  describe "sync_repos/0" do
    test "creates owners and repos from installations, and detects devcontainers" do
      expect(ClientMock, :list_installations, fn _ ->
        {:ok, [%{"id" => 77, "account" => %{"login" => "acme", "type" => "User", "id" => 9}}]}
      end)

      expect(ClientMock, :installation_token, fn _, 77 -> {:ok, "ghs_install"} end)

      expect(ClientMock, :list_installation_repos, fn "ghs_install" ->
        {:ok,
         [
           %{
             "full_name" => "acme/storefront",
             "name" => "storefront",
             "id" => 1,
             "default_branch" => "main",
             "private" => true,
             "archived" => false
           },
           %{
             "full_name" => "acme/notes",
             "name" => "notes",
             "id" => 2,
             "default_branch" => "trunk",
             "private" => false,
             "archived" => false
           },
           %{"full_name" => "acme/old", "name" => "old", "id" => 3, "archived" => true}
         ]}
      end)

      stub(ClientMock, :list_dir, fn _, _, ".devcontainer" -> {:error, :not_found} end)

      stub(ClientMock, :get_file, fn
        _, "acme/storefront", ".devcontainer/devcontainer.json", nil ->
          {:ok, ~s({
             // jsonc
             "dockerComposeFile": "docker-compose.yml",
             "service": "app",
             "hostRequirements": {"cpus": 8, "memory": "16gb"},
             "features": {"ghcr.io/acme/private-feature:1": {}, "ghcr.io/devcontainers/features/node:1": {}},
           })}

        _, _, _, _ ->
          {:error, :not_found}
      end)

      assert {:ok, 3} = GitHub.sync_repos()

      storefront = Foreman.Repos.get_repo_by_full_name("acme/storefront")
      assert storefront.devcontainer_path == ".devcontainer/devcontainer.json"
      assert storefront.host_requirements == %{"cpus" => 8, "memory" => "16gb"}
      assert storefront.private_registry_refs == ["ghcr.io/acme/private-feature:1"]
      assert storefront.owner.installation_id == 77

      notes = Foreman.Repos.get_repo_by_full_name("acme/notes")
      assert notes.devcontainer_path == nil
      assert notes.default_branch == "trunk"

      assert Foreman.Repos.get_repo_by_full_name("acme/old") == nil

      assert Foreman.Repos.list_repos(with_devcontainer: true) |> Enum.map(& &1.full_name) == [
               "acme/storefront"
             ]
    end

    test "finds configs in .devcontainer subfolders and flags non-compose ones" do
      stub(ClientMock, :list_dir, fn _, _, ".devcontainer" ->
        {:ok, [%{"type" => "dir", "name" => "web"}, %{"type" => "file", "name" => "x"}]}
      end)

      stub(ClientMock, :get_file, fn
        _, _, ".devcontainer/web/devcontainer.json", _ ->
          {:ok, ~s({"image": "mcr.microsoft.com/devcontainers/base"})}

        _, _, _, _ ->
          {:error, :not_found}
      end)

      result = GitHub.detect_devcontainer("t", "acme/x", "acme")
      assert result.devcontainer_path == ".devcontainer/web/devcontainer.json"
      assert result.devcontainer_error =~ "compose"
    end
  end

  describe "user_token/1" do
    test "returns a fresh token without refreshing" do
      user = user_fixture(access_token: "ghu_fresh")
      assert {:ok, "ghu_fresh"} = GitHub.user_token(user)
    end

    test "refreshes a token about to expire and stores the new pair" do
      user =
        user_fixture(
          access_token: "ghu_old",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 60)
        )

      refresh = user.refresh_token

      expect(ClientMock, :refresh_user_token, fn _, ^refresh ->
        {:ok,
         %{
           access_token: "ghu_new",
           refresh_token: "ghr_new",
           expires_in: 28_800,
           refresh_token_expires_in: 15_000_000
         }}
      end)

      assert {:ok, "ghu_new"} = GitHub.user_token(user)
      user = Repo.reload!(user)
      assert user.refresh_token == "ghr_new"

      # The new token is fresh, so the next call doesn't refresh again.
      assert {:ok, "ghu_new"} = GitHub.user_token(user)
    end

    test "concurrent refreshes spend the refresh token once" do
      user =
        user_fixture(
          access_token: "ghu_old",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 60)
        )

      test_pid = self()

      stub(ClientMock, :refresh_user_token, fn _, _ ->
        send(test_pid, :refreshed)
        Process.sleep(50)

        {:ok,
         %{
           access_token: "ghu_new",
           refresh_token: "ghr_new",
           expires_in: 28_800,
           refresh_token_expires_in: 15_000_000
         }}
      end)

      tasks =
        for _ <- 1..4,
            do:
              Task.async(fn ->
                Mox.allow(ClientMock, test_pid, self()) && GitHub.user_token(user)
              end)

      assert Enum.all?(Task.await_many(tasks), &(&1 == {:ok, "ghu_new"}))
      assert_received :refreshed
      refute_received :refreshed
    end
  end

  describe "manifest flow" do
    test "the manifest points GitHub back at this deployment" do
      manifest = GitHub.manifest("https://foreman.example.ts.net", "Foreman")
      assert manifest["redirect_url"] == "https://foreman.example.ts.net/setup/github/created"
      assert manifest["callback_urls"] == ["https://foreman.example.ts.net/auth/github/callback"]
      assert manifest["public"] == false
      assert manifest["default_permissions"]["contents"] == "write"
    end

    test "completing it stores the app's credentials encrypted" do
      Application.delete_env(:foreman, :github_app)

      expect(ClientMock, :convert_manifest, fn "code123" ->
        {:ok,
         %{
           "id" => 5,
           "slug" => "foreman-mona",
           "client_id" => "Iv1.new",
           "client_secret" => "sek",
           "pem" => "-----BEGIN RSA PRIVATE KEY-----",
           "html_url" => "https://github.com/apps/foreman-mona"
         }}
      end)

      assert {:ok, _} = GitHub.complete_manifest("code123")
      assert %{client_id: "Iv1.new", slug: "foreman-mona"} = GitHub.app()

      raw = Repo.one(from s in "settings", where: s.key == "github_app", select: s.value)
      refute raw =~ "sek"
    end
  end

  describe "registry credentials" do
    test "need read:packages and must pull every private reference" do
      expect(ClientMock, :check_classic_token, fn "ghp_x" ->
        {:ok, %{login: "bot", scopes: ["repo"], expires_at: nil}}
      end)

      assert {:error, message} = GitHub.check_registry_credential("ghcr.io", "bot", "ghp_x", [])
      assert message =~ "read:packages"

      expect(ClientMock, :check_classic_token, fn "ghp_y" ->
        {:ok, %{login: "bot", scopes: ["read:packages"], expires_at: nil}}
      end)

      expect(ClientMock, :check_registry_pull, fn "ghcr.io", "bot", "ghp_y", "ghcr.io/w/base:1" ->
        {:error, {:http, 403}}
      end)

      assert {:error, message} =
               GitHub.check_registry_credential("ghcr.io", "bot", "ghp_y", ["ghcr.io/w/base:1"])

      assert message =~ "ghcr.io/w/base:1"

      expect(ClientMock, :check_classic_token, fn "ghp_z" ->
        {:ok, %{login: "bot", scopes: ["read:packages"], expires_at: ~U[2027-01-01 00:00:00Z]}}
      end)

      expect(ClientMock, :check_registry_pull, fn _, _, _, _ -> :ok end)

      assert {:ok, %{expires_at: ~U[2027-01-01 00:00:00Z]}} =
               GitHub.check_registry_credential("ghcr.io", "bot", "ghp_z", ["ghcr.io/w/base:1"])
    end
  end

  describe "JWT" do
    test "app tokens are RS256 and verify with the app's public key" do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      jwt = Foreman.GitHub.JWT.app_token("Iv1.x", pem, 1_000_000)

      [h, c, s] = String.split(jwt, ".")
      assert %{"alg" => "RS256"} = h |> Base.url_decode64!(padding: false) |> JSON.decode!()

      assert %{"iss" => "Iv1.x", "exp" => 1_000_540, "iat" => 999_940} =
               c |> Base.url_decode64!(padding: false) |> JSON.decode!()

      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key

      assert :public_key.verify(
               h <> "." <> c,
               :sha256,
               Base.url_decode64!(s, padding: false),
               {:RSAPublicKey, n, e}
             )
    end
  end
end
