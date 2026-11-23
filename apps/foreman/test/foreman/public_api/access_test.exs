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

    expect(ClientMock, :user_installation_membership, fn token, installation, wanted ->
      assert token == user.access_token
      assert installation == owner.installation_id

      remote = MapSet.new([{122, repo.full_name}, {124, "another/name"}])
      assert MapSet.size(wanted) == 3
      {:ok, MapSet.intersection(wanted, remote)}
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

  test "listing and point lookup use the same policy for manual and synced repositories" do
    github_config()
    user = user_fixture()
    principal = principal(user)
    owner = owner_fixture()
    synced = repo_fixture(owner: owner) |> github_id(45)
    manual = repo_fixture(owner: owner) |> change(manual: true, github_id: 83) |> Repo.update!()
    stub(ClientMock, :user_installation_membership, fn _, _, _ -> {:ok, MapSet.new()} end)

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
    stub(ClientMock, :user_installation_membership, fn _, _, _ -> {:ok, MapSet.new()} end)

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

    expect(ClientMock, :user_installation_membership, 2, fn _, installation, wanted ->
      assert installation == repo.owner.installation_id
      assert wanted == MapSet.new([{442, repo.full_name}])
      {:ok, wanted}
    end)

    assert ids(Access.environments(principal)) == [history.id]
    assert ids(Access.environments(principal, history.id)) == [history.id]
  end

  test "service resources follow the installation, including when a grant changes before a query runs" do
    installer = user_fixture(role: "admin")
    scope = Foreman.Scope.for_user(installer)
    granted_repo = repo_fixture() |> github_id(817)
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

  test "a pre-binding workspace never consults GitHub, including on the collection path" do
    github_config()
    user = user_fixture()
    actor = principal(user)
    repo = repo_fixture() |> change(manual: true) |> Repo.update!()
    env = environment_fixture(user: user, repo: repo)
    Repo.update!(change(repo, github_id: 812, github_identity_bound_at: DateTime.utc_now()))

    deny(ClientMock, :get_repo, 2)
    assert ids(Access.environments(actor, env.id)) == []
    assert ids(Access.environments(actor)) == []
  end

  test "service registration and existing grants require approval of the bound identity" do
    github_config()
    alias Foreman.OAuth.ServiceAccounts
    scope = Foreman.Scope.for_user(user_fixture(role: "admin"))
    legacy = repo_fixture() |> change(manual: true) |> Repo.update!()
    box = box_fixture()

    attrs = %{
      "name" => "Build",
      "scopes" => ["repos:list"],
      "repo_ids" => [legacy.id],
      "box_ids" => [box.id]
    }

    assert {:error, :invalid_resource} = ServiceAccounts.register(scope, "service", attrs)
    refute Enum.any?(ServiceAccounts.choices(scope).repos, fn {id, _} -> id == legacy.id end)

    # A service created on the old version could approve a name-only row.
    {:ok, %{grant: old}} = ServiceAccounts.register(scope, "service", %{attrs | "repo_ids" => []})
    old = Repo.update!(change(old, repo_ids: [legacy.id]))
    {:ok, actor} = Foreman.OAuth.authorize_grant(old.id)
    prepared = Access.repos(actor)
    # Even a tie at the database's timestamp precision cannot prove approval followed binding.
    bound =
      Repo.update!(change(legacy, github_id: 812, github_identity_bound_at: old.inserted_at))

    env = environment_fixture(user: actor.user, repo: bound, box: box)
    assert ids(prepared) == []
    assert ids(Access.environments(actor, env.id)) == []
    assert ServiceAccounts.repo_ids(actor) == []

    {:ok, %{grant: fresh}} = ServiceAccounts.register(scope, "service", attrs)
    {:ok, approved} = Foreman.OAuth.authorize_grant(fresh.id)
    assert ids(Access.repos(approved)) == [bound.id]
    assert ServiceAccounts.repo_ids(approved) == [bound.id]
  end

  test "a prepared query rechecks the inactivity deadline on each execution" do
    actor = principal(user_fixture())
    box = box_fixture(owner_user_id: actor.user.id)
    query = Access.boxes(actor)
    # expires_at is set after query construction, so a captured BEAM clock
    # will still admit this grant after its subsecond deadline passes.
    deadline = DateTime.add(DateTime.utc_now(), 150, :millisecond)

    Repo.update_all(from(g in Foreman.OAuth.Grant, where: g.id == ^actor.grant_id),
      set: [expires_at: deadline]
    )

    assert ids(query) == [box.id]

    if Repo.sqlite?() do
      Repo.query!(
        "UPDATE oauth_grants SET expires_at = replace(rtrim(expires_at, 'Z'), 'T', ' ') WHERE id = ?",
        [actor.grant_id]
      )

      assert ids(query) == [box.id]
    end

    Process.sleep(max(1, DateTime.diff(deadline, DateTime.utc_now(), :millisecond) + 10))
    assert ids(query) == []
  end

  test "identity migration fences historical manual workspaces and leaves synced workspaces accessible" do
    github_config()
    actor = principal(user_fixture())
    manual = repo_fixture() |> change(manual: true, github_id: 815) |> Repo.update!()
    synced = repo_fixture() |> github_id(816)
    unbound = repo_fixture() |> change(manual: true) |> Repo.update!()
    old = environment_fixture(user: actor.user, repo: manual)
    live = environment_fixture(user: actor.user, repo: synced)
    # Both IDs were available for installation under the previous schema.
    {:ok, %{grant: legacy_grant}} =
      Foreman.OAuth.ServiceAccounts.register(
        Foreman.Scope.for_user(user_fixture(role: "admin")),
        "service",
        %{
          "name" => "Existing CI",
          "scopes" => ["repos:list"],
          "repo_ids" => [manual.id, synced.id]
        }
      )

    {:ok, service} = Foreman.OAuth.authorize_grant(legacy_grant.id)
    # Recreate the preceding release's schema and apply the actual migration inside this sandbox.
    migrations = [
      {20_261_123_010_000, Foreman.Repo.Migrations.RecordRepoIdentityBinding,
       "record_repo_identity_binding"},
      {20_261_123_010_001, Foreman.Repo.Migrations.SnapshotRepositoryBindings,
       "snapshot_repository_bindings"}
    ]

    for {version, _, name} <- migrations do
      Code.require_file(
        Path.join(:code.priv_dir(:foreman), "repo/migrations/#{version}_#{name}.exs")
      )
    end

    for {version, migration, _} <- Enum.reverse(migrations) do
      assert :ok = Ecto.Migrator.down(Repo, version, migration, log: false, migration_lock: false)
    end

    for {version, migration, _} <- migrations do
      assert :ok = Ecto.Migrator.up(Repo, version, migration, log: false, migration_lock: false)
    end

    assert DateTime.after?(Repo.reload!(manual).github_identity_bound_at, old.inserted_at)
    assert is_nil(Repo.reload!(synced).github_identity_bound_at)
    assert is_nil(Repo.reload!(unbound).github_identity_bound_at)
    assert ids(Access.environments(actor, old.id)) == []
    expect(ClientMock, :user_installation_membership, fn _, _, wanted -> {:ok, wanted} end)
    assert ids(Access.environments(actor, live.id)) == [live.id]
    assert ids(Access.repos(service)) == [synced.id]
    assert Foreman.OAuth.ServiceAccounts.repo_ids(service) == [synced.id]
  end

  test "retained personal queries keep the verified repository and installation across transfers" do
    github_config()
    actor = principal(user_fixture())
    owner = owner_fixture()
    target = owner_fixture()
    repo = repo_fixture(owner: owner) |> github_id(92)
    workspace = environment_fixture(user: actor.user, repo: repo)
    stub(ClientMock, :user_installation_membership, fn _, _, wanted -> {:ok, wanted} end)

    catalog = Access.repos(actor)
    history = Access.environments(actor, workspace.id)
    assert ids(catalog) == [repo.id]
    assert ids(history) == [workspace.id]

    {:ok, transferred} =
      Foreman.Repos.upsert_repo(target, %{
        github_id: 92,
        full_name: target.login <> "/" <> repo.name,
        name: repo.name
      })

    assert transferred.id == repo.id
    assert ids(catalog) == []
    assert ids(history) == []

    verified = Access.repos(actor)
    Repo.update!(change(target, installation_id: target.installation_id + 1000))
    assert ids(verified) == []

    verified = Access.repos(actor)
    Repo.update!(change(transferred, manual: true))
    assert ids(verified) == []
  end

  test "a workspace records the repository identity observed at submission" do
    github_config()
    actor = principal(user_fixture())
    unbound = repo_fixture() |> change(manual: true) |> Repo.update!()

    {:ok, bound} =
      Foreman.Repos.upsert_repo(unbound.owner, %{
        full_name: unbound.full_name,
        name: unbound.name,
        github_id: 814
      })

    # Both rows are inserted after the bind. Only one creator saw that identity.
    stale = environment_fixture(user: actor.user, repo: unbound)
    fresh = environment_fixture(user: actor.user, repo: bound)
    stub(ClientMock, :get_repo, fn _, name -> {:ok, %{"id" => 814, "full_name" => name}} end)
    assert ids(Access.environments(actor)) == [fresh.id]
    assert ids(Access.environments(actor, stale.id)) == []
  end

  test "service credentials retain an archived primary only for an accessible workspace" do
    github_config()
    alias Foreman.OAuth.ServiceAccounts
    admin = Foreman.Scope.for_user(user_fixture(role: "admin"))
    primary = repo_fixture() |> github_id(890)
    secondary = repo_fixture() |> github_id(891)
    box = box_fixture()

    {:ok, %{grant: grant}} =
      ServiceAccounts.register(admin, "service", %{
        "name" => "CI",
        "scopes" => ["repos:list"],
        "repo_ids" => [primary.id, secondary.id],
        "box_ids" => [box.id]
      })

    {:ok, actor} = Foreman.OAuth.authorize_grant(grant.id)
    workspace = environment_fixture(user: actor.user, repo: primary, box: box)
    Repo.update!(change(primary, archived: true))
    Repo.update!(change(secondary, archived: true))
    assert ids(Access.environments(actor)) == [workspace.id]
    assert ids(Access.repos(actor)) == []
    assert ServiceAccounts.repo_ids(actor) == []
    assert ServiceAccounts.repo_ids(actor, secondary.id) == []
    assert ServiceAccounts.repo_ids(actor, primary.id) == [primary.id]
    Repo.update!(change(workspace, created_once: false))
    assert ServiceAccounts.repo_ids(actor, primary.id) == []
    Repo.update!(change(Repo.reload!(workspace), created_once: true))
    Repo.update!(change(box, revoked_at: DateTime.utc_now()))
    assert ServiceAccounts.repo_ids(actor, primary.id) == []
  end

  test "personal verification updates shared catalog and workload eligibility for manual repos" do
    github_config()
    alias Foreman.OAuth.ServiceAccounts
    admin = user_fixture(role: "admin")
    scope = Foreman.Scope.for_user(admin)
    person = principal(admin)
    repo = repo_fixture() |> change(manual: true, github_id: 892) |> Repo.update!()
    box = box_fixture()

    {:ok, %{grant: grant}} =
      ServiceAccounts.register(scope, "service", %{
        "name" => "CI",
        "scopes" => ["repos:list"],
        "repo_ids" => [repo.id],
        "box_ids" => [box.id]
      })

    {:ok, service} = Foreman.OAuth.authorize_grant(grant.id)
    existing = environment_fixture(user: service.user, repo: repo, box: box)
    personal_history = environment_fixture(user: admin, repo: repo)
    catalog = Access.repos(service)
    assert ids(catalog) == [repo.id]

    expect(ClientMock, :get_repo, fn _, name ->
      {:ok, %{"id" => 892, "full_name" => name, "archived" => true}}
    end)

    assert ids(Access.repos(person, repo.id)) == []
    assert Repo.reload!(repo).archived
    assert ids(catalog) == []
    assert ServiceAccounts.repo_ids(service, Ecto.UUID.generate()) == []
    assert ServiceAccounts.repo_ids(service, repo.id) == [repo.id]
    assert ids(Access.environments(service)) == [existing.id]

    expect(ClientMock, :get_repo, fn _, name ->
      {:ok, %{"id" => 892, "full_name" => name, "archived" => true}}
    end)

    assert ids(Access.environments(person, personal_history.id)) == [personal_history.id]

    expect(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
    assert_raise Access.Unavailable, fn -> Access.environments(person, personal_history.id) end
    assert Repo.reload!(repo).archived

    expect(ClientMock, :get_repo, fn _, name ->
      {:ok, %{"id" => 893, "full_name" => name, "archived" => false}}
    end)

    assert ids(Access.repos(person, repo.id)) == []
    assert Repo.reload!(repo).archived

    expect(ClientMock, :get_repo, fn _, name ->
      {:ok, %{"id" => 892, "full_name" => name, "archived" => false}}
    end)

    assert ids(Access.repos(person)) == [repo.id]
    refute Repo.reload!(repo).archived
    assert ids(catalog) == [repo.id]
  end

  test "a grant approves the selected numeric repository even if a binding write commits later" do
    github_config()
    alias Foreman.OAuth.ServiceAccounts
    repo = repo_fixture() |> github_id(920)
    earlier = DateTime.utc_now()

    {:ok, %{grant: grant}} =
      ServiceAccounts.register(Foreman.Scope.for_user(user_fixture(role: "admin")), "service", %{
        "name" => "Build",
        "scopes" => ["repos:list"],
        "repo_ids" => [repo.id]
      })

    {:ok, actor} = Foreman.OAuth.authorize_grant(grant.id)
    query = Access.repos(actor)
    assert ids(query) == [repo.id]
    Repo.update!(change(repo, github_id: 921, github_identity_bound_at: earlier))
    assert ids(query) == []
    assert ServiceAccounts.repo_ids(actor) == []
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
