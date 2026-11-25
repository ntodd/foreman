defmodule Foreman.OAuth.EnvironmentConnectionTest do
  @moduledoc "The authority a box's relayed request carries for one environment."
  use Foreman.DataCase

  import Foreman.PublicAPIMutationFixtures, only: [local_git: 1]

  alias Foreman.OAuth
  alias Foreman.OAuth.{EnvironmentConnection, Grant, Scopes}
  alias Foreman.PublicAPI.{Access, Secrets}

  setup :local_git

  setup do
    user = user_fixture()
    repo = repo_fixture() |> Ecto.Changeset.change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo, box: box)
    sibling = environment_fixture(user: user, repo: repo, box: box)

    %{user: user, repo: repo, box: box, env: env, sibling: sibling}
  end

  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  defp connect(ctx, env \\ nil),
    do: EnvironmentConnection.principal(ctx.box.id, (env || ctx.env).id)

  defp grants(env),
    do: Repo.all(from g in Grant, where: g.environment_id == ^env.id, order_by: g.inserted_at)

  test "acts as the environment's owner, with the actions an environment gets", ctx do
    assert {:ok, principal} = connect(ctx)

    assert principal.user.id == ctx.user.id
    assert principal.kind == :user
    assert principal.client_id == "foreman-environment"
    assert principal.environment_id == ctx.env.id
    assert Enum.sort(principal.scopes) == Enum.sort(Scopes.environment())

    for refused <- ~w(environments:destroy environments:create repos:list boxes:list),
        do: refute(refused in principal.scopes)

    for needed <- ~w(environments:read environments:start environments:stop
                     secrets:list secrets:write operations:read logs:read attachments:create),
        do: assert(needed in principal.scopes)
  end

  test "reaches its own environment and nothing beside it", ctx do
    other_box = box_fixture(owner_user_id: ctx.user.id)
    elsewhere = environment_fixture(user: ctx.user, repo: ctx.repo, box: other_box)
    {:ok, principal} = connect(ctx)

    assert ids(Access.live_environments(principal)) == [ctx.env.id]
    assert ids(Access.environments(principal)) == [ctx.env.id]

    for other <- [ctx.sibling, elsewhere] do
      assert Repo.all(Access.live_environments(principal, other.id)) == []
      assert Repo.all(Access.environments(principal, other.id)) == []
    end

    # The owner could list these through a connection of their own.
    assert ids(Access.repos(principal)) == []
    assert Repo.all(Access.repos(principal, ctx.repo.id)) == []
    assert ids(Access.boxes(principal)) == [ctx.box.id]
  end

  test "manages the environment's own secrets and no other scope, even for an admin", ctx do
    admin = user_fixture(role: "admin")
    box = box_fixture(owner_user_id: admin.id)
    env = environment_fixture(user: admin, repo: ctx.repo, box: box)
    other = environment_fixture(user: admin, repo: ctx.repo, box: box)
    {:ok, principal} = EnvironmentConnection.principal(box.id, env.id)

    assert {:ok, "environment", %{id: id}} = Secrets.subject(principal, "environment", env.id)
    assert id == env.id

    assert {:error, :missing} = Secrets.subject(principal, "environment", other.id)
    assert {:error, :role} = Secrets.subject(principal, "user", "me")
    assert {:error, :role} = Secrets.subject(principal, "user", admin.id)
    assert {:error, :role} = Secrets.subject(principal, "repo", ctx.repo.id)
    assert {:error, :role} = Secrets.subject(principal, "owner", ctx.repo.owner.login)
  end

  test "is one grant per environment, however often and however concurrently it is asked for",
       ctx do
    {:ok, first} = connect(ctx)
    {:ok, second} = connect(ctx)
    assert first.grant_id == second.grant_id

    {:ok, sibling} = connect(ctx, ctx.sibling)
    assert sibling.grant_id != first.grant_id
    assert sibling.environment_id == ctx.sibling.id

    assert [%Grant{user_id: user_id, client_id: "foreman-environment"}] = grants(ctx.env)
    assert user_id == ctx.user.id
  end

  test "work queued on the grant is authorized again inside the same environment", ctx do
    {:ok, principal} = connect(ctx)

    assert {:ok, again} = OAuth.authorize_grant(principal.grant_id)
    assert again.environment_id == ctx.env.id
    assert ids(Access.live_environments(again)) == [ctx.env.id]
  end

  test "only the box the environment runs on can ask", ctx do
    other_box = box_fixture(owner_user_id: ctx.user.id)

    assert {:error, :not_found} = EnvironmentConnection.principal(other_box.id, ctx.env.id)

    assert {:error, :not_found} =
             EnvironmentConnection.principal(ctx.box.id, Ecto.UUID.generate())

    assert {:error, :not_found} = EnvironmentConnection.principal(ctx.box.id, "not-a-uuid")
    assert {:error, :not_found} = EnvironmentConnection.principal("not-a-uuid", ctx.env.id)
    assert grants(ctx.env) == []

    Repo.update!(Ecto.Changeset.change(ctx.box, revoked_at: DateTime.utc_now()))
    assert {:error, :not_found} = connect(ctx)
  end

  test "ends with the environment", ctx do
    {:ok, principal} = connect(ctx)

    Repo.update!(Ecto.Changeset.change(ctx.env, destroyed_at: DateTime.utc_now()))

    assert {:error, :not_found} = connect(ctx)
    assert :error = OAuth.authorize_grant(principal.grant_id)
  end

  test "ends when the owner is disabled, and a service account's environment has none", ctx do
    {:ok, principal} = connect(ctx)
    Repo.update!(Ecto.Changeset.change(ctx.user, disabled_at: DateTime.utc_now()))

    assert {:error, :not_found} = connect(ctx)
    assert :error = OAuth.authorize_grant(principal.grant_id)

    service = user_fixture() |> Ecto.Changeset.change(service_account: true) |> Repo.update!()
    box = box_fixture(owner_user_id: service.id)
    env = environment_fixture(user: service, repo: ctx.repo, box: box)

    assert {:error, :not_found} = EnvironmentConnection.principal(box.id, env.id)
    assert grants(env) == []
  end

  test "a revoked grant stays revoked, and the next request gets a new one", ctx do
    {:ok, first} = connect(ctx)
    OAuth.revoke_grant(first.grant_id)
    assert :error = OAuth.authorize_grant(first.grant_id)

    {:ok, second} = connect(ctx)
    assert second.grant_id != first.grant_id
    assert :error = OAuth.authorize_grant(first.grant_id)
    assert length(grants(ctx.env)) == 2
  end

  test "a grant made with an older list of actions is brought to the current one", ctx do
    {:ok, principal} = connect(ctx)

    Repo.update_all(from(g in Grant, where: g.id == ^principal.grant_id),
      set: [scopes: ["environments:read", "environments:destroy"]]
    )

    {:ok, again} = connect(ctx)
    assert again.grant_id == principal.grant_id
    assert Enum.sort(again.scopes) == Enum.sort(Scopes.environment())
  end

  test "isn't listed with the apps the owner connected", ctx do
    {actor, _grant} = Foreman.PublicAPIMutationFixtures.principal(ctx.user)
    {:ok, _} = connect(ctx)

    assert [%Grant{id: id}] = OAuth.connections(ctx.user.id)
    assert id == actor.grant_id
  end

  test "an ordinary connection is unchanged: it has no environment", ctx do
    {actor, _grant} = Foreman.PublicAPIMutationFixtures.principal(ctx.user)

    assert actor.environment_id == nil
    assert ids(Access.live_environments(actor)) == Enum.sort([ctx.env.id, ctx.sibling.id])
  end
end
