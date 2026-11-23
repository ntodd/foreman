defmodule Foreman.PublicAPI.AccessTest do
  use Foreman.DataCase

  import Mox

  alias Foreman.GitHub.ClientMock
  alias Foreman.PublicAPI.Access

  setup :verify_on_exit!

  test "owned and shared boxes are visible until the box is revoked or sharing ends" do
    user = user_fixture()
    principal = principal(user)
    mine = box_fixture(owner_user_id: user.id)
    shared = box_fixture(shared_user_ids: [user.id])
    _other = box_fixture()

    assert ids(Access.boxes(principal)) == Enum.sort([mine.id, shared.id])
    Repo.update!(Ecto.Changeset.change(shared, shared_user_ids: []))
    assert ids(Access.boxes(principal)) == [mine.id]
    Repo.update!(Ecto.Changeset.change(mine, revoked_at: DateTime.utc_now()))
    assert ids(Access.boxes(principal)) == []
  end

  test "GitHub-backed discovery checks the personal token and stable repository identity" do
    github_config()
    user = user_fixture(role: "admin")
    owner = owner_fixture()
    repo = repo_fixture(owner: owner) |> github_id(122)
    _hidden = repo_fixture(owner: owner) |> github_id(123)
    _renamed = repo_fixture(owner: owner) |> github_id(124)

    expect(ClientMock, :list_user_installation_repos, fn token, installation ->
      assert token == user.access_token
      assert installation == owner.installation_id

      {:ok,
       [
         %{"id" => 122, "full_name" => repo.full_name},
         %{"id" => 124, "full_name" => "another/name"}
       ]}
    end)

    assert ids(Access.repos(principal(user))) == [repo.id]
  end

  test "absence of the GitHub app does not open GitHub repositories to every client" do
    repo_fixture()
    assert ids(Access.repos(principal(user_fixture()))) == []
  end

  test "environment visibility requires ownership, repo access and box access even after destroy" do
    old = Application.get_env(:foreman, :git_base_url)
    Application.put_env(:foreman, :git_base_url, "http://git.fixture")
    on_exit(fn -> restore(:git_base_url, old) end)

    user = user_fixture()
    principal = principal(user)
    public_repo = repo_fixture() |> change(private: false) |> Repo.update!()
    mine = environment_fixture(user: user, repo: public_repo)

    tombstone =
      environment_fixture(user: user, repo: public_repo, destroyed_at: DateTime.utc_now())

    _private_repo = environment_fixture(user: user)

    _other_owner =
      environment_fixture(repo: public_repo, box: Repo.get!(Foreman.Boxes.Box, mine.box_id))

    _other_box = environment_fixture(user: user, repo: public_repo, box: box_fixture())
    assert ids(Access.environments(principal)) == Enum.sort([mine.id, tombstone.id])
  end

  test "polling a single environment checks only its repository and conceals other owners" do
    github_config()
    mine = user_fixture()
    principal = principal(mine)
    repo = repo_fixture() |> change(manual: true, github_id: 123) |> Repo.update!()
    env = environment_fixture(user: mine, repo: repo)
    other = environment_fixture()

    assert ids(Access.environments(principal, other.id)) == []

    expect(ClientMock, :get_repo, fn token, name ->
      assert token == mine.access_token
      assert name == repo.full_name
      {:ok, %{"id" => 123, "full_name" => name}}
    end)

    assert ids(Access.environments(principal, env.id)) == [env.id]
    expect(ClientMock, :get_repo, fn _, _ -> {:error, :not_found} end)
    assert ids(Access.environments(principal, env.id)) == []
  end

  test "unverified repository selectors are concealed; an outage reading owned history is retryable" do
    github_config()
    user = user_fixture()
    repo = repo_fixture() |> change(manual: true, github_id: 110) |> Repo.update!()
    env = environment_fixture(user: user, repo: repo)
    principal = principal(user)

    expect(ClientMock, :get_repo, 2, fn _, _ -> {:error, :timeout} end)

    assert ids(Access.repos(principal, repo.id)) ==
             ids(Access.repos(principal, Ecto.UUID.generate()))

    error = assert_raise Access.Unavailable, fn -> Access.environments(principal, env.id) end
    assert Plug.Exception.status(error) == 503

    assert %{code: "repository_access_unavailable", message: message} =
             ForemanWeb.ErrorJSON.render("503.json", %{reason: error})

    assert message == Exception.message(error)
  end

  test "live environment reads skip repositories belonging only to destroyed workspaces" do
    github_config()
    user = user_fixture()
    principal = principal(user)
    active_repo = repo_fixture() |> change(manual: true, github_id: 411) |> Repo.update!()
    gone_repo = repo_fixture() |> change(manual: true, github_id: 412) |> Repo.update!()
    active = environment_fixture(user: user, repo: active_repo)
    gone = environment_fixture(user: user, repo: gone_repo, destroyed_at: DateTime.utc_now())

    stub(ClientMock, :get_repo, fn _, name ->
      if name == active_repo.full_name,
        do: {:ok, %{"id" => 411, "full_name" => name}},
        else: {:error, :timeout}
    end)

    conn = Phoenix.ConnTest.build_conn() |> Plug.Conn.assign(:api_principal, principal)

    assert %{"items" => [%{"id" => id}]} =
             conn
             |> ForemanWeb.PublicReadController.environments(%{})
             |> Phoenix.ConnTest.json_response(200)

    assert id == active.id

    assert conn
           |> ForemanWeb.PublicReadController.environment(%{"id" => gone.id})
           |> Phoenix.ConnTest.json_response(404)

    assert_raise Access.Unavailable, fn -> Access.environments(principal, gone.id) end
  end

  test "listing and point lookup use the same policy for manual and synced repositories" do
    github_config()
    user = user_fixture()
    principal = principal(user)
    owner = owner_fixture()
    synced = repo_fixture(owner: owner) |> github_id(45)
    manual = repo_fixture(owner: owner) |> change(manual: true, github_id: 83) |> Repo.update!()
    stub(ClientMock, :list_user_installation_repos, fn _, _ -> {:ok, []} end)

    stub(ClientMock, :get_repo, fn _, name ->
      assert name == manual.full_name
      {:ok, %{"id" => 83, "full_name" => name}}
    end)

    assert ids(Access.repos(principal)) == [manual.id]
    assert ids(Access.repos(principal, manual.id)) == [manual.id]
    assert ids(Access.repos(principal, synced.id)) == []
  end

  test "a legacy name alone cannot expose its old workspace when an admin binds the repo" do
    github_config()
    admin = user_fixture(role: "admin")
    principal = principal(admin)
    legacy = repo_fixture() |> change(manual: true) |> Repo.update!()
    old = environment_fixture(repo: legacy, user: admin)
    stub(ClientMock, :list_user_installation_repos, fn _, _ -> {:ok, []} end)

    stub(ClientMock, :get_repo, fn _, name ->
      {:ok, %{"id" => 378, "full_name" => name, "private" => true}}
    end)

    assert ids(Access.environments(principal, old.id)) == []
    assert {:ok, bound} = Foreman.Repos.add_repo(Foreman.Scope.for_user(admin), legacy.full_name)
    assert bound.github_id == 378
    assert ids(Access.repos(principal)) == [legacy.id]
    assert ids(Access.environments(principal, old.id)) == []
    new = environment_fixture(repo: bound, user: admin)
    assert ids(Access.environments(principal)) == [new.id]
    stub(ClientMock, :get_repo, fn _, name -> {:ok, %{"id" => 379, "full_name" => name}} end)
    assert ids(Access.environments(principal, new.id)) == []
  end

  test "archived repositories keep owned history; unrelated installations cannot interrupt it" do
    github_config()
    user = user_fixture()
    principal = principal(user)
    repo = repo_fixture() |> change(archived: true, github_id: 442) |> Repo.update!()
    other = repo_fixture() |> github_id(443)
    environment_fixture(repo: other)
    assert ids(Access.environments(principal)) == []
    history = environment_fixture(repo: repo, user: user, destroyed_at: DateTime.utc_now())

    expect(ClientMock, :list_user_installation_repos, 2, fn _, installation ->
      assert installation == repo.owner.installation_id
      {:ok, [%{"id" => 442, "full_name" => repo.full_name}]}
    end)

    assert ids(Access.environments(principal)) == [history.id]
    assert ids(Access.environments(principal, history.id)) == [history.id]
  end

  test "service resources follow the installation, including when a grant changes before a query runs" do
    installer = user_fixture(role: "admin")
    scope = Foreman.Scope.for_user(installer)
    granted_repo = repo_fixture()
    other_repo = repo_fixture()
    granted_box = box_fixture()
    other_box = box_fixture(owner_user_id: installer.id)

    assert {:ok, %{grant: grant, client: client, secret: _}} =
             Foreman.OAuth.ServiceAccounts.register(scope, "service", %{
               "name" => "Team build",
               "scopes" => ["environments:list"],
               "repo_ids" => [granted_repo.id],
               "box_ids" => [granted_box.id]
             })

    assert {:ok, principal} = Foreman.OAuth.authorize_grant(grant.id)
    env = environment_fixture(user: principal.user, repo: granted_repo, box: granted_box)
    _installer_env = environment_fixture(user: installer, repo: granted_repo, box: granted_box)
    _other_repo = environment_fixture(user: principal.user, repo: other_repo, box: granted_box)
    _other_box = environment_fixture(user: principal.user, repo: granted_repo, box: other_box)
    authorized = Access.environments(principal)
    assert ids(authorized) == [env.id]
    assert ids(Access.repos(principal)) == [granted_repo.id]
    assert ids(Access.boxes(principal)) == [granted_box.id]

    # The installer and installation have distinct lifetimes.
    Repo.update!(change(installer, disabled_at: DateTime.utc_now()))
    assert ids(authorized) == [env.id]

    assert {:ok, :disabled} =
             Foreman.OAuth.ServiceAccounts.disable(
               Foreman.Scope.for_user(user_fixture(role: "admin")),
               client.id
             )

    assert ids(authorized) == []
  end

  test "existing personal queries observe role changes, disable and connection revocation" do
    admin = user_fixture(role: "admin")
    first = principal(admin)
    second = principal(admin)
    owned = box_fixture(owner_user_id: admin.id)
    shared = box_fixture(shared_user_ids: [admin.id])
    other = box_fixture()
    query = Access.boxes(first)
    another = Access.boxes(second)
    assert ids(query) == Enum.sort([owned.id, shared.id, other.id])
    Repo.update!(change(admin, role: "member"))
    assert ids(query) == Enum.sort([owned.id, shared.id])

    Repo.update_all(from(g in Foreman.OAuth.Grant, where: g.id == ^first.grant_id),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert ids(query) == []
    assert ids(another) == Enum.sort([owned.id, shared.id])
    Repo.update!(change(admin, disabled_at: DateTime.utc_now()))
    assert ids(another) == []
  end

  defp principal(user) do
    grant =
      Repo.insert!(%Foreman.OAuth.Grant{
        user_id: user.id,
        client_id: "foreman-cli",
        scopes: Foreman.OAuth.Scopes.all()
      })

    {:ok, principal} = Foreman.OAuth.authorize_grant(grant.id)
    principal
  end

  defp github_config do
    old = Application.get_env(:foreman, :github_app)

    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "test",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> restore(:github_app, old) end)
  end

  defp restore(key, nil), do: Application.delete_env(:foreman, key)
  defp restore(key, value), do: Application.put_env(:foreman, key, value)
  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  defp github_id(repo, id), do: repo |> Ecto.Changeset.change(github_id: id) |> Repo.update!()
end
