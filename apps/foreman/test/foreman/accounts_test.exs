defmodule Foreman.AccountsTest do
  use Foreman.DataCase, async: true

  alias Foreman.Accounts
  alias Foreman.Accounts.User
  alias Foreman.Scope

  @profile %{
    "id" => 42,
    "login" => "mona",
    "name" => "Mona",
    "avatar_url" => "https://avatars.example/42"
  }
  @tokens %{
    access_token: "ghu_a",
    refresh_token: "ghr_b",
    expires_in: 28_800,
    refresh_token_expires_in: 15_897_600
  }

  describe "sign_in_from_github/3" do
    test "the first user becomes admin when no admins are configured" do
      assert {:ok, %User{login: "mona", role: "admin"} = user} =
               Accounts.sign_in_from_github(@profile, @tokens,
                 config: %{admins: [], allowed_users: [], allowed_org: nil},
                 org_member?: false
               )

      assert user.access_token == "ghu_a"
      assert DateTime.compare(user.access_token_expires_at, DateTime.utc_now()) == :gt
    end

    test "after that, only allowed users get in" do
      config = %{admins: [], allowed_users: [], allowed_org: nil}

      {:ok, _} =
        Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)

      other = %{@profile | "id" => 43, "login" => "stranger"}

      assert {:error, :not_allowed} =
               Accounts.sign_in_from_github(other, @tokens, config: config, org_member?: false)
    end

    test "configured admins are admins; allowed users and org members are members" do
      config = %{admins: ["mona"], allowed_users: ["alice"], allowed_org: "acme"}

      assert {:ok, %User{role: "admin"}} =
               Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)

      alice = %{@profile | "id" => 1, "login" => "alice"}

      assert {:ok, %User{role: "member"}} =
               Accounts.sign_in_from_github(alice, @tokens, config: config, org_member?: false)

      bob = %{@profile | "id" => 2, "login" => "bob"}

      assert {:error, :not_allowed} =
               Accounts.sign_in_from_github(bob, @tokens, config: config, org_member?: false)

      assert {:ok, %User{role: "member"}} =
               Accounts.sign_in_from_github(bob, @tokens, config: config, org_member?: true)
    end

    test "configured logins match whatever case GitHub returns" do
      config = %{admins: ["Mona"], allowed_users: ["ALICE"], allowed_org: nil}

      assert {:ok, %User{login: "mona", role: "admin"} = mona} =
               Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)

      assert {:ok, %User{role: "admin"}} =
               Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)

      alice = %{@profile | "id" => 1, "login" => "Alice"}

      assert {:ok, %User{login: "Alice", role: "member"} = alice} =
               Accounts.sign_in_from_github(alice, @tokens, config: config, org_member?: false)

      assert Accounts.access(mona, config) == :allowed
      assert Accounts.access(alice, config) == :allowed
    end

    test "matches users by GitHub id, so a renamed account keeps its data" do
      config = %{admins: ["mona"], allowed_users: [], allowed_org: nil}

      {:ok, user} =
        Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)

      renamed = %{@profile | "login" => "monalisa"}
      config = %{config | admins: ["monalisa"]}

      assert {:ok, %User{id: id, login: "monalisa"}} =
               Accounts.sign_in_from_github(renamed, @tokens, config: config, org_member?: false)

      assert id == user.id
    end

    test "disabled users can't sign in" do
      user = user_fixture(login: "mona", github_id: 42)
      Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))
      config = %{admins: ["mona"], allowed_users: [], allowed_org: nil}

      assert {:error, :disabled} =
               Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)
    end

    test "signing in clears an expired GitHub login" do
      user = user_fixture(login: "mona", github_id: 42)
      Repo.update!(Ecto.Changeset.change(user, github_login_expired: true))
      config = %{admins: ["mona"], allowed_users: [], allowed_org: nil}

      assert {:ok, %User{github_login_expired: false}} =
               Accounts.sign_in_from_github(@profile, @tokens, config: config, org_member?: false)
    end
  end

  describe "sessions" do
    test "a session token finds its user, and only a hash is stored" do
      user = user_fixture()
      token = Accounts.create_session(user, "Firefox")

      assert %User{id: id} = Accounts.get_user_by_session(token)
      assert id == user.id

      [session] = Repo.all(Foreman.Accounts.Session)
      refute session.token_hash == token

      assert session.token_hash ==
               :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "deleted, expired and garbage tokens find nothing" do
      user = user_fixture()
      token = Accounts.create_session(user, nil)
      Accounts.delete_session(token)
      assert Accounts.get_user_by_session(token) == nil

      token = Accounts.create_session(user, nil)

      Repo.update_all(Foreman.Accounts.Session,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -31 * 86_400)]
      )

      assert Accounts.get_user_by_session(token) == nil

      assert Accounts.get_user_by_session("not base64 !!") == nil
      assert Accounts.get_user_by_session(nil) == nil
    end

    test "a disabled user's sessions stop working" do
      user = user_fixture()
      token = Accounts.create_session(user, nil)
      Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))
      assert Accounts.get_user_by_session(token) == nil
    end
  end

  describe "git identity and dotfiles" do
    test "repo overrides beat user defaults field by field" do
      user = user_fixture(git_name: "Mona", git_email: "mona@example.com")

      {:ok, user} =
        Accounts.update_preferences(Scope.for_user(user), %{
          "dotfiles_repository" => "https://github.com/mona/dotfiles.git"
        })

      repo = repo_fixture()

      assert %{
               git_name: "Mona",
               git_email: "mona@example.com",
               dotfiles_repository: "https://github.com/mona/dotfiles.git"
             } =
               Accounts.effective_identity(user, repo)

      {:ok, _} =
        Accounts.put_repo_setting(Scope.for_user(user), repo, %{
          "git_email" => "mona@work.example"
        })

      assert %{
               git_name: "Mona",
               git_email: "mona@work.example",
               dotfiles_repository: "https://github.com/mona/dotfiles.git"
             } =
               Accounts.effective_identity(user, repo)
    end

    test "rejects identities that could inject git config" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_preferences(Scope.for_user(user), %{
                 "git_name" => "x\n[core]\n\tfsmonitor = evil"
               })

      assert errors_on(changeset).git_name != []

      assert {:error, changeset} =
               Accounts.update_preferences(Scope.for_user(user), %{"git_email" => "a\"@b"})

      assert errors_on(changeset).git_email != []

      assert {:error, changeset} =
               Accounts.update_preferences(Scope.for_user(user), %{
                 "dotfiles_repository" => "git@github.com:x/y"
               })

      assert errors_on(changeset).dotfiles_repository != []
    end

    test "a repo can override where the dotfiles go" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_preferences(Scope.for_user(user), %{
          "dotfiles_repository" => "https://github.com/mona/dotfiles.git",
          "dotfiles_target_path" => "~/.dotfiles"
        })

      repo = repo_fixture()
      assert %{dotfiles_target_path: "~/.dotfiles"} = Accounts.effective_identity(user, repo)

      {:ok, _} =
        Accounts.put_repo_setting(Scope.for_user(user), repo, %{
          "dotfiles_target_path" => "/home/mona/dots"
        })

      assert %{dotfiles_target_path: "/home/mona/dots"} = Accounts.effective_identity(user, repo)
    end

    # The devcontainer CLI puts the path in its clone script unquoted.
    test "the dotfiles path is a plain home or absolute path" do
      scope = Scope.for_user(user_fixture())

      for path <- ["~/.dotfiles", "~/src/dotfiles", "/home/mona/.dotfiles", "~/dot_files-1"] do
        assert {:ok, _} = Accounts.update_preferences(scope, %{"dotfiles_target_path" => path}),
               path
      end

      for path <- [
            "dotfiles",
            "~",
            "~/",
            "~mona/dotfiles",
            "~/../etc",
            "/tmp/./x",
            "~/dots; rm -rf ~",
            "~/$(id)",
            "~/a b",
            "~/dots\n"
          ] do
        assert {:error, changeset} =
                 Accounts.update_preferences(scope, %{"dotfiles_target_path" => path}),
               inspect(path)

        assert errors_on(changeset).dotfiles_target_path != []
      end
    end
  end

  describe "devcontainer features" do
    @orca "ghcr.io/ntodd/devcontainer-features/orca:1"
    @node "ghcr.io/devcontainers/features/node:1"

    test "go on every repo, less the ones a repo turns off, and nobody else's" do
      user = user_fixture()
      other = user_fixture()
      repo = repo_fixture()
      features = %{@orca => %{"server" => true, "port" => "4100"}, @node => %{}}

      assert {:ok, user} = Accounts.update_features(Scope.for_user(user), features)
      assert user.devcontainer_features == features
      assert Accounts.effective_features(user, repo) == features
      assert Accounts.effective_features(other, repo) == %{}

      {:ok, _} =
        Accounts.put_repo_setting(Scope.for_user(user), repo, %{
          "disabled_features" => ["ghcr.io/ntodd/devcontainer-features/orca"]
        })

      assert Accounts.effective_features(user, repo) == %{@node => %{}}
      assert Accounts.effective_features(user, repo_fixture()) == features

      # Turned off by feature, not by version.
      {:ok, user} =
        Accounts.update_features(Scope.for_user(user), %{
          "ghcr.io/ntodd/devcontainer-features/orca:2" => %{}
        })

      assert Accounts.effective_features(user, repo) == %{}
    end

    test "refuses what an environment couldn't install, naming the feature" do
      scope = Scope.for_user(user_fixture())

      for {features, message} <- [
            {%{"./local-feature" => %{}}, "./local-feature"},
            {%{"https://example.com/f.tgz" => %{}}, "https://example.com/f.tgz"},
            {%{"ghcr.io/mona/features/foreman:1" => %{}}, "Foreman"},
            {%{@orca => %{}, "ghcr.io/ntodd/devcontainer-features/orca:2" => %{}}, "twice"},
            {%{@orca => %{"port" => 4100}}, @orca},
            {%{@orca => %{"bad name" => "x"}}, @orca},
            {%{@orca => "server"}, @orca},
            {%{@orca => nil}, @orca},
            {%{"ghcr.io/acme/features/x:ReleaseA" => %{}}, "ReleaseA"},
            {[@orca], "object"}
          ] do
        assert {:error, changeset} = Accounts.update_features(scope, features)

        assert Enum.any?(errors_on(changeset).devcontainer_features, &(&1 =~ message)),
               "expected #{inspect(features)} to be refused with #{message}: " <>
                 inspect(errors_on(changeset))
      end
    end

    test "changes are audited by ref, without their options" do
      user = user_fixture()
      scope = Scope.for_user(user)

      {:ok, _} = Accounts.update_features(scope, %{@orca => %{"token" => "s3cret"}})
      {:ok, _} = Accounts.update_features(Scope.for_user(Repo.reload!(user)), %{@node => %{}})

      events =
        Foreman.Audit.recent()
        |> Enum.filter(&(&1.action == "user.features" and &1.subject_id == user.id))

      assert [second, first] = events
      assert first.metadata == %{"added" => [@orca], "removed" => [], "changed" => []}
      assert second.metadata == %{"added" => [@node], "removed" => [@orca], "changed" => []}
      refute inspect(events) =~ "s3cret"
    end

    test "a repo can only turn off features by their ref, without a version" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.put_repo_setting(Scope.for_user(user), repo_fixture(), %{
                 "disabled_features" => ["not a ref"]
               })

      assert errors_on(changeset).disabled_features != []
    end
  end

  describe "roles" do
    test "only admins change roles, and they can't demote themselves" do
      admin = user_fixture(role: "admin")
      member = user_fixture()

      assert {:error, :unauthorized} = Accounts.set_role(Scope.for_user(member), admin, "member")

      assert {:ok, %User{role: "admin"}} =
               Accounts.set_role(Scope.for_user(admin), member, "admin")

      assert {:error, :self} = Accounts.set_role(Scope.for_user(admin), admin, "member")
    end
  end
end
