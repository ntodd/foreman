defmodule Foreman.PublicAPI.RepositoryBindingConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Foreman.Fixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Foreman.{Environments, OAuth, Repo, Repos, Scope}
  alias Foreman.PublicAPI.Access

  setup :verify_on_exit!

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture(role: "admin")
    owner = owner_fixture()

    repo =
      repo_fixture(owner: owner)
      |> Ecto.Changeset.change(private: false, manual: true)
      |> Repo.update!()

    box = box_fixture(owner_user_id: user.id)

    grant =
      Repo.insert!(%OAuth.Grant{
        user_id: user.id,
        client_id: "foreman-cli",
        scopes: ["environments:list"]
      })

    {:ok, principal} = OAuth.authorize_grant(grant.id)

    on_exit(fn ->
      Foreman.DataCase.stop_environment_servers()

      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from e in Foreman.Audit.Event, where: e.actor_id == ^user.id)
        Repo.delete_all(from o in Foreman.Operations.Operation, where: o.box_id == ^box.id)
        Repo.delete_all(from e in Environments.Environment, where: e.box_id == ^box.id)
        Repo.delete!(box)
        Repo.delete!(repo)
        Repo.delete!(owner)
        Repo.delete!(user)
      end)
    end)

    %{principal: principal, user: user, box: box, repo: repo, owner: owner}
  end

  test "a browser create that observed a name-only row stays outside the API after concurrent first binding",
       ctx do
    config(:git_base_url, "http://git.fixture")
    config(:github_app, %{})
    config(:tailscale, %{client_id: "fixture", client_secret: "fixture"})
    parent = self()

    expect(Foreman.Tailscale.ClientMock, :list_devices, fn _ ->
      send(parent, {:repo_selected, self()})

      receive do
        :bound -> {:ok, []}
      after
        5000 -> flunk("binding did not commit")
      end
    end)

    pending =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Environments.create_environment(Scope.for_user(ctx.user), %{
          repo_id: ctx.repo.id,
          box_id: ctx.box.id
        })
      end)

    assert_receive {:repo_selected, creator}, 3000

    assert {:ok, _} =
             Repos.upsert_repo(ctx.owner, %{
               full_name: ctx.repo.full_name,
               name: ctx.repo.name,
               github_id: 3901
             })

    send(creator, :bound)
    assert {:ok, workspace} = Task.await(pending)
    refute Repo.exists?(Access.environments(ctx.principal, workspace.id))
  end

  test "installation changes committed during remote verification invalidate the returned query",
       ctx do
    config(:github_app, %{app_id: "1", client_id: "fixture", client_secret: "s", private_key: "k"})

    repo = ctx.repo |> Ecto.Changeset.change(manual: false, github_id: 3902) |> Repo.update!()
    parent = self()

    expect(Foreman.GitHub.ClientMock, :user_installation_membership, fn _, _, wanted ->
      send(parent, {:checking_membership, self()})

      receive do
        :transferred -> {:ok, wanted}
      after
        5000 -> flunk("installation change did not commit")
      end
    end)

    pending =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        Repo.all(Access.repos(ctx.principal, repo.id))
      end)

    assert_receive {:checking_membership, verifier}, 3000

    ctx.owner
    |> Ecto.Changeset.change(installation_id: ctx.owner.installation_id + 1_000_000)
    |> Repo.update!()

    send(verifier, :transferred)
    assert Task.await(pending) == []
  end

  test "service approval keeps the binding read by the registration transaction", ctx do
    config(:git_base_url, "http://git.fixture")
    config(:github_app, %{})
    parent = self()

    pending =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        receive do
          :register -> :ok
        end

        OAuth.ServiceAccounts.register(Scope.for_user(ctx.user), "service", %{
          "name" => ctx.user.id,
          "repo_ids" => [ctx.repo.id],
          "box_ids" => [ctx.box.id],
          "scopes" => ["repos:list"]
        })
      end)

    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:foreman, :repo, :query],
        &__MODULE__.after_resource_read/4,
        {pending.pid, parent}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(pending.pid, :register)
    # Registration selected the unbound repository and is still in its transaction.
    assert_receive :registration_selected, 3000

    binder =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        send(parent, {:binding_started, self()})

        Repos.upsert_repo(ctx.owner, %{
          full_name: ctx.repo.full_name,
          name: ctx.repo.name,
          github_id: 3903
        })
      end)

    assert_receive {:binding_started, _}, 3000
    # SQLite serializes both writers. PostgreSQL can commit the bind while
    # approval is paused between its resource check and the grant insert.
    if Repo.sqlite?(), do: send(pending.pid, :continue)
    assert {:ok, _} = Task.await(binder)
    unless Repo.sqlite?(), do: send(pending.pid, :continue)
    assert {:ok, %{grant: grant, client: client}} = Task.await(pending)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(client)
        Repo.delete!(Repo.get!(Foreman.Accounts.User, grant.user_id))
      end)
    end)

    {:ok, actor} = OAuth.authorize_grant(grant.id)
    assert OAuth.ServiceAccounts.repo_ids(actor) == []
  end

  @doc false
  def after_resource_read(_, _, %{source: "boxes"}, {registrar, parent})
      when registrar == self() do
    send(parent, :registration_selected)

    receive do
      :continue -> :ok
    after
      5000 -> raise "registration did not resume"
    end
  end

  def after_resource_read(_, _, _, _), do: :ok

  defp config(key, value) do
    previous = Application.fetch_env(:foreman, key)
    Application.put_env(:foreman, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:foreman, key, old)
        :error -> Application.delete_env(:foreman, key)
      end
    end)
  end
end
