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
