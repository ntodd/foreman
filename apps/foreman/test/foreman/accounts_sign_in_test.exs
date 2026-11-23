defmodule Foreman.AccountsSignInTest do
  # Who gets which account at sign-in, and losing access when that changes.
  use Foreman.DataCase

  alias Foreman.{Accounts, Scope}

  defp sign_in(id, login, config, opts \\ []) do
    Accounts.sign_in_from_github(
      %{"id" => id, "login" => login, "name" => login, "avatar_url" => nil},
      %{access_token: "ghu_#{id}", refresh_token: "ghr_#{id}"},
      Keyword.merge([config: config], opts)
    )
  end

  describe "identity" do
    test "a confirmed membership loss fences the first sign-in across a login rename" do
      config = %{admins: [], allowed_users: [], allowed_org: "acme"}

      check = fn "acme" ->
        assert {:error, :not_allowed} = sign_in(101, "renamed", config, org_member?: false)
        assert Accounts.list_users() == []
        true
      end

      assert {:error, :access_changed} =
               sign_in(101, "first-login", config, check_membership: check)

      assert Accounts.list_users() == []
      assert {:ok, user} = sign_in(101, "renamed", config, org_member?: true)
      assert is_binary(Accounts.create_session(user, "fresh membership"))
    end

    test "an unknown membership or a different GitHub identity does not cancel a first sign-in" do
      config = %{admins: [], allowed_users: [], allowed_org: "acme"}

      check = fn "acme" ->
        assert {:error, :not_allowed} = sign_in(101, "first-login", config, org_member?: :unknown)
        assert {:error, :not_allowed} = sign_in(102, "first-login", config, org_member?: false)
        true
      end

      assert {:ok, user} = sign_in(101, "first-login", config, check_membership: check)
      assert user.github_id == 101
    end

    test "a membership denial revokes a user created while the first check was pending" do
      config = %{admins: [], allowed_users: [], allowed_org: "acme"}

      check = fn "acme" ->
        assert {:ok, user} = sign_in(101, "first-login", config, org_member?: true)
        assert is_binary(Accounts.create_session(user, "first sign-in"))
        false
      end

      assert {:error, :not_allowed} = sign_in(101, "first-login", config, check_membership: check)
      refute Repo.exists?(Accounts.Session)
      assert Accounts.get_user_by_login("first-login").github_login_expired
    end

    test "a new GitHub account that takes a renamed user's old login gets a new account" do
      alice = user_fixture(login: "alice", github_id: 100, role: "admin")
      config = %{admins: ["root"], allowed_users: ["alice"], allowed_org: nil}

      assert {:ok, user} = sign_in(200, "alice", config)
      refute user.id == alice.id
      assert user.role == "member"
      assert user.login == "alice"

      # The old record keeps its GitHub id and gets its login back when its
      # owner signs in under the new name.
      stale = Repo.reload!(alice)
      assert stale.github_id == 100
      refute stale.login == "alice"

      config = %{config | allowed_users: ["alice", "alice-renamed"]}
      assert {:ok, renamed} = sign_in(100, "alice-renamed", config)
      assert renamed.id == alice.id
      assert renamed.login == "alice-renamed"
      assert renamed.role == "admin"
    end

    test "a record without a GitHub id is claimed by login" do
      user = user_fixture(login: "carol", github_id: nil)
      config = %{admins: [], allowed_users: ["carol"], allowed_org: nil}

      assert {:ok, signed_in} = sign_in(300, "carol", config)
      assert signed_in.id == user.id
      assert signed_in.github_id == 300
    end
  end

  describe "who may sign in" do
    test "a config grant ends when the login leaves FOREMAN_ADMINS" do
      config = %{admins: ["BoB"], allowed_users: ["bob"], allowed_org: nil}
      assert {:ok, %{role: "admin", admin_via_config: true} = bob} = sign_in(300, "bob", config)
      token = Accounts.create_session(bob, "test browser")
      config = %{config | admins: []}

      assert Accounts.get_user_by_session(token).role == "member"
      assert {:ok, %{role: "member", admin_via_config: false}} = sign_in(300, "bob", config)
    end

    test "the access check revokes config grants and refreshes connected clients" do
      config = %{admins: ["bob"], allowed_users: [], allowed_org: "acme"}
      {:ok, bob} = sign_in(300, "bob", config)
      member = user_fixture(role: "admin")
      ForemanWeb.Endpoint.subscribe("user_sessions:#{bob.id}")

      Accounts.revoke_removed_config_admins(%{config | admins: []})
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert Repo.reload!(bob).role == "member"
      assert Repo.reload!(member).role == "admin"
    end

    test "an explicit local grant survives being added to and removed from configuration" do
      user_fixture(login: "bob", github_id: 300, role: "admin")
      config = %{admins: ["bob"], allowed_users: ["bob"], allowed_org: nil}
      assert {:ok, %{role: "admin", admin_via_config: false}} = sign_in(300, "bob", config)
      assert {:ok, %{role: "admin"}} = sign_in(300, "bob", %{config | admins: []})
    end

    test "an admin no longer configured or in the org is refused" do
      user_fixture(login: "bob", github_id: 300, role: "admin")
      config = %{admins: ["root"], allowed_users: [], allowed_org: "acme"}

      assert {:error, :not_allowed} = sign_in(300, "bob", config, org_member?: false)
    end

    test "an admin promoted in the UI still signs in while they're in the org" do
      user_fixture(login: "dana", github_id: 400, role: "admin")
      config = %{admins: ["root"], allowed_users: [], allowed_org: "acme"}

      assert {:ok, %{role: "admin"}} = sign_in(400, "dana", config, org_member?: true)
    end

    test "a first-claim admin keeps signing in after an allowlist is set without FOREMAN_ADMINS" do
      config = %{admins: [], allowed_users: [], allowed_org: nil}
      assert {:ok, %{role: "admin"} = owner} = sign_in(700, "owner", config)

      config = %{config | allowed_users: ["friend"]}
      assert {:ok, signed_in} = sign_in(700, "owner", config)
      assert signed_in.id == owner.id
      assert signed_in.role == "admin"
    end

    test "an admin promoted in the UI signs in without FOREMAN_ADMINS or an org" do
      user_fixture(login: "gail", github_id: 800, role: "admin")
      config = %{admins: [], allowed_users: ["friend"], allowed_org: nil}

      assert {:ok, %{role: "admin"}} = sign_in(800, "gail", config)
    end

    test "with an org configured, an admin promoted in the UI has to stay in it" do
      user_fixture(login: "gil", github_id: 810, role: "admin")
      config = %{admins: [], allowed_users: [], allowed_org: "acme"}

      assert {:ok, %{role: "admin"}} = sign_in(810, "gil", config, org_member?: true)
      assert {:error, :not_allowed} = sign_in(810, "gil", config, org_member?: false)

      assert Accounts.access(Repo.get_by!(Foreman.Accounts.User, login: "gil"), config) ==
               :ask_org
    end

    test "with FOREMAN_ADMINS set, an admin dropped from it and the org is refused" do
      user_fixture(login: "hank", github_id: 900, role: "admin")
      config = %{admins: ["root"], allowed_users: ["friend"], allowed_org: "acme"}

      assert {:error, :not_allowed} = sign_in(900, "hank", config, org_member?: false)
    end

    test "a disabled admin is refused whatever is configured" do
      user_fixture(
        login: "ivy",
        github_id: 950,
        role: "admin",
        disabled_at: DateTime.utc_now()
      )

      config = %{admins: [], allowed_users: [], allowed_org: nil}

      assert {:error, :disabled} = sign_in(950, "ivy", config)
    end

    test "with nothing configured, existing users still sign in" do
      user_fixture(login: "erin", github_id: 500, role: "admin")
      config = %{admins: [], allowed_users: [], allowed_org: nil}

      assert {:ok, _} = sign_in(500, "erin", config)
      assert {:error, :not_allowed} = sign_in(501, "stranger", config)
    end
  end

  describe "open LiveViews" do
    setup do
      admin = user_fixture(role: "admin")
      user = user_fixture()
      ForemanWeb.Endpoint.subscribe("user_sessions:#{user.id}")
      %{admin: admin, user: user}
    end

    test "are disconnected when the user is disabled", %{admin: admin, user: user} do
      {:ok, _} = Accounts.set_disabled(Scope.for_user(admin), user, true)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "are disconnected when the user's role changes", %{admin: admin, user: user} do
      {:ok, _} = Accounts.set_role(Scope.for_user(admin), user, "admin")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end
end
