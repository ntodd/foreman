defmodule Foreman.TokenPermissionsTest do
  # What an environment's scoped GitHub token may do: the defaults, a
  # repo's own choices, and the cap from what the GitHub App's
  # installation was actually granted.
  use Foreman.DataCase

  import Mox

  alias Foreman.{GitHub, Repos, Scope}
  alias Foreman.GitHub.ClientMock
  alias Foreman.Repos.TokenPermissions

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

  @everything %{
    "contents" => "write",
    "pull_requests" => "write",
    "issues" => "write",
    "workflows" => "write",
    "actions" => "write",
    "checks" => "write",
    "statuses" => "write",
    "deployments" => "write",
    "discussions" => "write",
    "pages" => "write",
    "metadata" => "read"
  }

  defp requested(repo) do
    test_pid = self()

    expect(ClientMock, :scope_user_token, fn _app, _token, _target, _repos, perms ->
      send(test_pid, {:perms, perms})
      {:ok, %{token: "ghs_scoped", expires_at: nil}}
    end)

    {:ok, "ghs_scoped"} = GitHub.environment_token(user_fixture(), Repo.preload(repo, :owner))
    assert_receive {:perms, perms}
    perms
  end

  describe "defaults" do
    test "cover development and CI, with checks and statuses read-only" do
      assert TokenPermissions.defaults() == %{
               "contents" => "write",
               "pull_requests" => "write",
               "issues" => "write",
               "workflows" => "write",
               "actions" => "write",
               "checks" => "read",
               "statuses" => "read",
               "deployments" => "none",
               "discussions" => "none",
               "pages" => "none"
             }
    end

    test "a repo without its own choices asks for them, plus metadata" do
      repo = repo_fixture(owner: owner_fixture(installation_permissions: @everything))

      assert requested(repo) == %{
               "contents" => "write",
               "pull_requests" => "write",
               "issues" => "write",
               "workflows" => "write",
               "actions" => "write",
               "checks" => "read",
               "statuses" => "read",
               "metadata" => "read"
             }
    end
  end

  describe "a repo's own choices" do
    test "turn permissions off and on" do
      owner = owner_fixture(installation_permissions: @everything)

      repo =
        repo_fixture(owner: owner)
        |> Ecto.Changeset.change(
          token_permissions:
            Map.merge(TokenPermissions.defaults(), %{"actions" => "none", "pages" => "write"})
        )
        |> Repo.update!()

      perms = requested(repo)
      refute Map.has_key?(perms, "actions")
      assert perms["pages"] == "write"
      assert perms["metadata"] == "read"
    end

    test "only take known permissions at levels GitHub allows" do
      repo = repo_fixture()
      admin = Scope.for_user(user_fixture(role: "admin"))

      for bad <- [
            %{"administration" => "write"},
            %{"workflows" => "read"},
            %{"issues" => "admin"}
          ] do
        perms = Map.merge(TokenPermissions.defaults(), bad)

        assert {:error, %Ecto.Changeset{} = cs} =
                 Repos.update_repo_settings(admin, repo, %{"token_permissions" => perms})

        assert cs.errors[:token_permissions]
      end
    end

    test "matching the defaults stores nothing, so later defaults still apply" do
      repo = repo_fixture()
      admin = Scope.for_user(user_fixture(role: "admin"))

      {:ok, repo} =
        Repos.update_repo_settings(admin, repo, %{
          "token_permissions" => TokenPermissions.defaults()
        })

      assert repo.token_permissions == nil

      changed = Map.put(TokenPermissions.defaults(), "checks", "write")
      {:ok, repo} = Repos.update_repo_settings(admin, repo, %{"token_permissions" => changed})
      assert repo.token_permissions == changed
    end
  end

  describe "the installation's cap" do
    test "drops what the app wasn't granted and lowers write to read" do
      owner =
        owner_fixture(
          installation_permissions: %{
            "contents" => "write",
            "pull_requests" => "write",
            "issues" => "read",
            "workflows" => "write",
            "metadata" => "read",
            "members" => "read"
          }
        )

      assert requested(repo_fixture(owner: owner)) == %{
               "contents" => "write",
               "pull_requests" => "write",
               "issues" => "read",
               "workflows" => "write",
               "metadata" => "read"
             }
    end

    test "before the first sync, assumes what every Foreman app has had" do
      owner = owner_fixture(installation_permissions: nil)

      assert requested(repo_fixture(owner: owner)) == %{
               "contents" => "write",
               "pull_requests" => "write",
               "issues" => "write",
               "workflows" => "write",
               "metadata" => "read"
             }
    end

    test "comes from the installation at sync" do
      expect(ClientMock, :list_installations, fn _ ->
        {:ok,
         [
           %{
             "id" => 77,
             "account" => %{"login" => "acme", "type" => "User", "id" => 9},
             "permissions" => %{"contents" => "write", "metadata" => "read"}
           }
         ]}
      end)

      expect(ClientMock, :installation_token, fn _, 77 -> {:ok, "ghs_install"} end)
      expect(ClientMock, :list_installation_repos, fn _ -> {:ok, []} end)

      {:ok, _} = GitHub.sync_repos()

      assert Repos.get_owner_by_login("acme").installation_permissions == %{
               "contents" => "write",
               "metadata" => "read"
             }
    end
  end

  test "the app manifest asks for everything environments can be given" do
    granted = GitHub.manifest("https://foreman.example", "Foreman")["default_permissions"]

    for {name, _label, levels} <- TokenPermissions.catalog() do
      assert granted[name] == List.last(levels), "manifest is missing #{name}"
    end
  end
end
