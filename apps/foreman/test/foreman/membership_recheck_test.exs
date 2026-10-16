defmodule Foreman.MembershipRecheckTest do
  # Who may use Foreman can change after sign-in. Each GitHub token
  # refresh (every few hours per active user) checks again; only a
  # definite "no" ends their access, never a GitHub error.
  use Foreman.DataCase

  import Mox

  alias Foreman.{Accounts, GitHub}
  alias Foreman.Audit.Event
  alias Foreman.GitHub.ClientMock

  setup :verify_on_exit!

  setup do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    saved =
      for key <- [:admins, :allowed_users, :allowed_org],
          do: {key, Application.get_env(:foreman, key)}

    on_exit(fn ->
      Application.delete_env(:foreman, :github_app)

      for {key, value} <- saved do
        if value == nil,
          do: Application.delete_env(:foreman, key),
          else: Application.put_env(:foreman, key, value)
      end
    end)

    user =
      user_fixture(
        login: "pat",
        access_token: "ghu_old",
        refresh_token: "ghr_old",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 60)
      )

    _token = Accounts.create_session(user, "test")
    %{user: user}
  end

  defp configure(admins, allowed_users, org) do
    Application.put_env(:foreman, :admins, admins)
    Application.put_env(:foreman, :allowed_users, allowed_users)
    Application.put_env(:foreman, :allowed_org, org)
  end

  defp refreshes do
    expect(ClientMock, :refresh_user_token, fn _, "ghr_old" ->
      {:ok,
       %{
         access_token: "ghu_new",
         refresh_token: "ghr_new",
         expires_in: 28_800,
         refresh_token_expires_in: 15_000_000
       }}
    end)
  end

  defp expire_login(user) do
    Repo.update!(
      Ecto.Changeset.change(user,
        github_login_expired: true,
        access_token: nil,
        refresh_token: nil
      )
    )
  end

  defp sessions(user),
    do: Repo.aggregate(from(s in Accounts.Session, where: s.user_id == ^user.id), :count)

  defp revoked?(user) do
    Repo.exists?(
      from e in Event, where: e.action == "user.access_revoked" and e.subject_id == ^user.id
    )
  end

  test "someone who left the org loses their sessions and tokens, not their account", %{
    user: user
  } do
    configure(["root"], [], "acme")
    refreshes()
    expect(ClientMock, :org_membership, fn "ghu_new", "acme" -> {:ok, false} end)
    ForemanWeb.Endpoint.subscribe("user_sessions:#{user.id}")

    assert {:error, :login_expired} = GitHub.user_token(user)

    reloaded = Repo.reload!(user)
    assert reloaded.github_login_expired
    assert reloaded.refresh_token == nil
    assert reloaded.disabled_at == nil
    assert sessions(user) == 0
    assert revoked?(user)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  test "a GitHub error while checking changes nothing", %{user: user} do
    configure(["root"], [], "acme")
    refreshes()
    expect(ClientMock, :org_membership, fn _, _ -> {:error, {:http, 502, "bad gateway"}} end)

    assert {:ok, "ghu_new"} = GitHub.user_token(user)
    assert sessions(user) == 1
    refute revoked?(user)
  end

  test "an active org member carries on", %{user: user} do
    configure(["root"], [], "acme")
    refreshes()
    expect(ClientMock, :org_membership, fn _, _ -> {:ok, true} end)

    assert {:ok, "ghu_new"} = GitHub.user_token(user)
    assert sessions(user) == 1
  end

  test "someone still on the allowlist isn't checked against GitHub", %{user: user} do
    configure(["root"], ["pat"], "acme")
    refreshes()

    assert {:ok, "ghu_new"} = GitHub.user_token(user)
    assert sessions(user) == 1
  end

  test "someone dropped from the allowlist, with no org configured, loses access", %{user: user} do
    configure(["root"], ["someone-else"], nil)
    refreshes()

    assert {:error, :login_expired} = GitHub.user_token(user)
    assert sessions(user) == 0
    assert revoked?(user)
  end

  test "with nothing configured, nobody is checked", %{user: user} do
    configure([], [], nil)
    refreshes()

    assert {:ok, "ghu_new"} = GitHub.user_token(user)
    assert sessions(user) == 1
  end

  test "after a revoke, environments get no GitHub token until they're let back in",
       %{user: user} do
    :ok = Accounts.revoke_access(user, "left the org")

    assert {:error, :login_expired} = GitHub.user_token(Repo.reload!(user))

    assert {:error, :login_expired} =
             GitHub.environment_token(user, repo_fixture(token_mode: "broad"))
  end

  describe "the periodic check of signed-in users" do
    # Someone with no environments never needs a token refreshed, so the
    # check above alone would leave their session alive for 30 days.

    test "catches someone who left the org even if their token is fresh", %{user: user} do
      configure(["root"], [], "acme")

      user =
        Repo.update!(
          Ecto.Changeset.change(user,
            access_token_expires_at: DateTime.add(DateTime.utc_now(), 6 * 3600, :second)
          )
        )

      expect(ClientMock, :org_membership, fn "ghu_old", "acme" -> {:ok, false} end)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 0
      assert revoked?(user)
    end

    test "checks a user whose token needs refreshing once, with the new token", %{user: user} do
      configure(["root"], [], "acme")
      refreshes()
      expect(ClientMock, :org_membership, fn "ghu_new", "acme" -> {:ok, true} end)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 1
    end

    test "leaves users without a session alone", %{user: user} do
      configure(["root"], [], "acme")
      Accounts.delete_user_sessions(user)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
    end

    test "signs out someone dropped from the allowlist even if their GitHub login expired",
         %{user: user} do
      configure(["root"], ["someone-else"], nil)
      expire_login(user)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 0
      assert revoked?(user)
    end

    test "signs out an expired login whose org membership can't be checked", %{user: user} do
      configure(["root"], [], "acme")
      expire_login(user)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 0
    end

    test "keeps an expired login that's still on the allowlist", %{user: user} do
      configure(["root"], ["pat"], "acme")
      expire_login(user)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 1
    end

    # The refresh finding the login dead is as definite as a "no": the
    # org can't be checked, so they're signed out now rather than in six
    # hours.
    test "signs out someone whose refresh token GitHub rejects", %{user: user} do
      configure(["root"], [], "acme")
      expect(ClientMock, :refresh_user_token, fn _, "ghr_old" -> {:error, :bad_refresh_token} end)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 0
    end

    test "someone the check itself refuses is signed out once", %{user: user} do
      configure(["root"], [], "acme")
      refreshes()
      expect(ClientMock, :org_membership, fn _, _ -> {:ok, false} end)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 0

      assert Repo.aggregate(
               from(e in Event,
                 where: e.action == "user.access_revoked" and e.subject_id == ^user.id
               ),
               :count
             ) == 1
    end

    test "a GitHub error changes nothing", %{user: user} do
      configure(["root"], [], "acme")
      refreshes()
      expect(ClientMock, :org_membership, fn _, _ -> {:error, :timeout} end)

      assert :ok = Foreman.Jobs.CheckAccess.perform(%Oban.Job{args: %{}})
      assert sessions(user) == 1
      refute revoked?(user)
    end
  end
end
