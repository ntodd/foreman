defmodule Foreman.WorkloadDeliveryConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Foreman.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Foreman.{Accounts, OAuth, Repo, Scope}
  alias Foreman.Environments.{Commands, WorkloadAccess}
  alias Foreman.Operations.Operation

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    previous = Application.get_env(:foreman, :git_base_url)
    Application.put_env(:foreman, :git_base_url, "http://git.fixture")
    admin = user_fixture(role: "admin")
    owner = owner_fixture()
    repo = repo_fixture(owner: owner) |> save(private: false, manual: true, github_id: unique())
    box = box_fixture(owner_user_id: admin.id)
    secret = secret_fixture("repo", repo, "CHOSEN", "initial", actor: admin)

    {:ok, %{client: client, grant: grant}} =
      OAuth.ServiceAccounts.register(Scope.for_user(admin), "service", %{
        "name" => admin.login,
        "repo_ids" => [repo.id],
        "box_ids" => [box.id],
        "scopes" => ~w(environments:create environments:start),
        "secret_ids" => [secret.id]
      })

    service = Accounts.get_user!(grant.user_id)
    env = environment_fixture(user: service, repo: repo, box: box) |> save(api_grant_id: grant.id)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman, :git_base_url, previous),
        else: Application.delete_env(:foreman, :git_base_url)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from e in Foreman.Audit.Event, where: e.actor_id == ^admin.id)
        Repo.delete!(env)
        Repo.delete!(client)
        Repo.delete!(service)
        Repo.delete!(secret)
        Repo.delete!(box)
        Repo.delete!(repo)
        Repo.delete!(owner)
        Repo.delete!(admin)
      end)
    end)

    op = %Operation{
      id: Ecto.UUID.generate(),
      action: "secrets_write",
      command: "env.secrets.write",
      box_id: box.id,
      environment_id: env.id,
      api_grant_id: grant.id,
      user_id: service.id,
      args: %{}
    }

    %{op: op, env: env, secret: secret}
  end

  test "selected secret rotation and mailbox delivery serialize in either order", %{
    secret: secret,
    op: op,
    env: env
  } do
    {:ok, _, _, old} = Commands.prepare(op, env)
    parent = self()

    writer =
      concurrent(fn ->
        Repo.transact(fn ->
          save(secret, value: "rotated")
          send(parent, :rotation_pending)
          await_release()
          {:ok, :rotated}
        end)
      end)

    assert_receive :rotation_pending, 3000

    reader =
      concurrent(fn ->
        send(parent, :delivery_started)
        WorkloadAccess.deliver(op, env, old, fn _ -> send(parent, :stale_delivery) end)
      end)

    assert_receive :delivery_started, 3000
    refute_receive :stale_delivery
    send(writer.pid, :release)
    assert {:ok, :rotated} = Task.await(writer)
    assert :retry = Task.await(reader)
    refute_received :stale_delivery

    {:ok, cmd, _, fresh} = Commands.prepare(op, env)
    assert cmd.payload.files["secrets.env"] =~ "rotated"

    delivery =
      concurrent(fn ->
        WorkloadAccess.deliver(op, env, fresh, fn _ ->
          send(parent, :in_delivery)
          await_release()
          :sent
        end)
      end)

    assert_receive :in_delivery, 3000

    rotation =
      concurrent(fn ->
        send(parent, :rotation_started)
        save(secret, value: "newest")
        send(parent, :rotation_committed)
      end)

    assert_receive :rotation_started, 3000
    refute_receive :rotation_committed
    send(delivery.pid, :release)
    assert :sent = Task.await(delivery)
    assert :rotation_committed = Task.await(rotation)
    assert :retry = WorkloadAccess.deliver(op, env, fresh, fn _ -> flunk("stale delivery") end)
  end

  defp concurrent(fun),
    do:
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        fun.()
      end)

  defp await_release do
    receive do
      :release -> :ok
    after
      5000 -> flunk("concurrent transaction did not resume")
    end
  end

  defp save(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
