defmodule Foreman.OAuthConcurrencyTest do
  use ExUnit.Case
  import Ecto.Query
  import Mox
  alias Ecto.Adapters.SQL.Sandbox
  alias Foreman.{Accounts, GitHub, OAuth, Repo}
  alias Foreman.Audit.Event
  alias Foreman.GitHub.ClientMock
  alias Foreman.OAuth.{Client, Grant}

  @moduletag skip:
               Foreman.Repo.database() != "postgres" &&
                 "requires independent PostgreSQL transactions"

  setup do
    # Each participant owns a separate, committing database connection. Fixtures
    # must be visible across those connections and are removed after each test.
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = Foreman.Fixtures.user_fixture(login: "race-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from e in Event, where: e.subject_id == ^user.id or e.actor_id == ^user.id
        )

        Repo.delete!(user)
      end)
    end)

    %{user: user, client: Repo.get!(Client, "foreman-cli")}
  end

  defp independent(fun) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:backend, self(), pid})
        fun.()
      end)

    task_pid = task.pid
    assert_receive {:backend, ^task_pid, pid}, 3000
    {task, pid}
  end

  defp wait_for_lock(pid) do
    assert Enum.any?(1..200, fn _ ->
             [[blocked]] = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [pid]).rows
             if !blocked, do: Process.sleep(10)
             blocked
           end),
           "database connection #{pid} never reached the contested lock"
  end

  defp issued(user, client) do
    grant = Repo.insert!(%Grant{user_id: user.id, client_id: client.id, scopes: ["repos:list"]})
    {:ok, tokens} = Repo.transact(fn -> {:ok, OAuth.issue(grant, grant.scopes, :user)} end)
    {grant, tokens}
  end

  defp github_sign_in(user) do
    before = Application.fetch_env(:foreman, :allowed_org)
    Application.put_env(:foreman, :allowed_org, "acme")

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:foreman, :allowed_org, value)
        :error -> Application.delete_env(:foreman, :allowed_org)
      end
    end)

    stub(ClientMock, :exchange_code, fn _, _, _, _ ->
      {:ok, %{access_token: "current", refresh_token: "refresh"}}
    end)

    stub(ClientMock, :get_user, fn _ ->
      {:ok, %{"id" => user.github_id, "login" => user.login}}
    end)
  end

  test "offboarding commits before a callback can persist an earlier positive membership decision",
       %{user: user} do
    github_sign_in(user)
    parent = self()

    stub(ClientMock, :org_membership, fn _, "acme" ->
      send(parent, :membership_checked)
      {:ok, true}
    end)

    {:ok, callback} =
      Repo.transact(fn ->
        :ok = Accounts.revoke_access(user, "confirmed loss")

        {callback, pid} =
          independent(fn -> GitHub.complete_sign_in("code", "verifier", "uri") end)

        assert_receive :membership_checked, 3000
        wait_for_lock(pid)
        {:ok, callback}
      end)

    assert {:error, _} = Task.await(callback)
    assert Repo.reload!(user).access_token == nil
    assert Accounts.create_session(user, "stale") == nil
    assert {:ok, fresh} = GitHub.complete_sign_in("fresh-code", "verifier", "uri")
    assert_receive :membership_checked
    assert is_binary(Accounts.create_session(fresh, "legitimate re-login"))
    assert is_nil(Accounts.create_session(user, "old callback after re-login"))
  end

  test "a positive membership reply in flight cannot undo completed offboarding", %{user: user} do
    github_sign_in(user)
    parent = self()

    stub(ClientMock, :org_membership, fn _, "acme" ->
      send(parent, {:positive_reply, self()})

      receive do
        :deliver -> {:ok, true}
      after
        3000 -> flunk("timed out waiting for offboarding")
      end
    end)

    {callback, _} = independent(fn -> GitHub.complete_sign_in("code", "verifier", "uri") end)
    assert_receive {:positive_reply, request}, 3000
    assert :ok = Accounts.revoke_access(user, "confirmed loss")
    send(request, :deliver)
    assert {:error, _} = Task.await(callback)
    assert Repo.reload!(user).github_login_expired
  end

  test "first sign-in waits for a pending denial of the same GitHub identity" do
    github_id = Foreman.Fixtures.unique()
    profile = %{"id" => github_id, "login" => "first-#{github_id}"}
    config = %{admins: [], allowed_users: [], allowed_org: "acme"}
    parent = self()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from g in "github_sign_in_generations", where: g.github_id == ^github_id)
      end)
    end)

    check = fn "acme" ->
      send(parent, :membership_requested)
      assert_receive :deliver_positive, 3000
      true
    end

    {callback, pid} =
      independent(fn ->
        Accounts.sign_in_from_github(profile, %{}, config: config, check_membership: check)
      end)

    assert_receive :membership_requested, 3000

    assert {:ok, :denied} =
             Repo.transact(fn ->
               assert {:error, :not_allowed} =
                        Accounts.sign_in_from_github(profile, %{},
                          config: config,
                          org_member?: false
                        )

               send(callback.pid, :deliver_positive)
               wait_for_lock(pid)
               {:ok, :denied}
             end)

    assert {:error, :access_changed} = Task.await(callback)
    refute Repo.get_by(Accounts.User, github_id: github_id)
  end

  test "registration waits for a concurrent administrator demotion", %{user: user} do
    admin = Repo.update!(Ecto.Changeset.change(user, role: "admin"))
    scope = Foreman.Scope.for_user(admin)
    name = "regression-#{admin.id}"

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Client, where: c.name == ^name)
      end)
    end)

    {:ok, task} =
      Repo.transact(fn ->
        Repo.one_for_update(from u in Accounts.User, where: u.id == ^admin.id)
        Repo.update!(Ecto.Changeset.change(admin, role: "member"))

        {task, pid} =
          independent(fn ->
            OAuth.ServiceAccounts.register(scope, "public", %{"name" => name})
          end)

        wait_for_lock(pid)
        {:ok, task}
      end)

    assert {:error, :unauthorized} = Task.await(task)
    refute Repo.exists?(from c in Client, where: c.name == ^name)
  end

  test "contending refreshes detect replay across two PostgreSQL connections", %{
    user: user,
    client: client
  } do
    {grant, tokens} = issued(user, client)

    {:ok, tasks} =
      Repo.transact(fn ->
        Repo.one_for_update(from u in Accounts.User, where: u.id == ^user.id)

        tasks =
          for _ <- 1..2 do
            {task, pid} = independent(fn -> OAuth.refresh(client, tokens.refresh_token, nil) end)
            wait_for_lock(pid)
            task
          end

        {:ok, tasks}
      end)

    assert [{:error, :invalid_grant}, {:ok, rotated}] = Enum.sort(Task.await_many(tasks))
    assert OAuth.authenticate(rotated.access_token) == :error
    assert OAuth.authorize_grant(grant.id) == :error
  end

  test "offboarding waiting on a successful rotation also revokes the replacement", %{
    user: user,
    client: client
  } do
    {grant, tokens} = issued(user, client)

    {:ok, {task, rotated}} =
      Repo.transact(fn ->
        {:ok, rotated} = OAuth.refresh(client, tokens.refresh_token, nil)
        {task, pid} = independent(fn -> Accounts.revoke_access(user, "offboard") end)
        wait_for_lock(pid)
        {:ok, {task, rotated}}
      end)

    assert :ok = Task.await(task)
    assert OAuth.authorize_grant(grant.id) == :error
    assert OAuth.authenticate(rotated.access_token) == :error
    assert {:error, :invalid_grant} = OAuth.refresh(client, rotated.refresh_token, nil)
  end

  test "a refresh already in progress observes committed offboarding", %{
    user: user,
    client: client
  } do
    {grant, tokens} = issued(user, client)

    {:ok, task} =
      Repo.transact(fn ->
        Accounts.revoke_access(user, "offboard")
        {task, pid} = independent(fn -> OAuth.refresh(client, tokens.refresh_token, nil) end)
        wait_for_lock(pid)
        {:ok, task}
      end)

    assert {:error, :invalid_grant} = Task.await(task)
    assert OAuth.authorize_grant(grant.id) == :error
    assert OAuth.authenticate(tokens.access_token) == :error
  end
end
