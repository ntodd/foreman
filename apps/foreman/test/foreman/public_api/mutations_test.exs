defmodule Foreman.PublicAPI.MutationsTest do
  use Foreman.DataCase

  import Foreman.PublicAPIMutationFixtures
  setup :local_git

  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation
  alias Foreman.PublicAPI.{Mutations, Receipt}

  setup do
    user = user_fixture()
    repo = repo_fixture() |> change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    {actor, _} = principal(user)
    %{actor: actor, user: user, repo: repo, box: box, input: %{"repo_id" => repo.id}}
  end

  defp online(box), do: Registry.register(Foreman.Registry, {:agent, box.id}, nil)

  test "placement, replay, changed defaults, attribution and a fresh key", ctx do
    online(ctx.box)

    shared =
      box_fixture(
        name: "a-shared",
        vm: %{"ready" => true},
        owner_user_id: user_fixture().id,
        shared_user_ids: [ctx.user.id]
      )

    online(shared)
    assert {:ok, env, op} = Mutations.create(ctx.actor, "first", ctx.input)
    assert %{box_id: box, branch: "main", api_grant_id: grant} = Repo.get!(Environment, env)
    assert is_nil(Repo.get!(Environment, env).expiry_at)
    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Jobs.EnvironmentExpiry")
    assert box == ctx.box.id
    assert grant == ctx.actor.grant_id
    assert %Operation{api_grant_id: ^grant, trigger: "request"} = Repo.get!(Operation, op)

    assert [
             %{
               actor_id: actor_id,
               metadata: %{"client_id" => "foreman-cli", "grant_id" => ^grant}
             }
           ] =
             Repo.all(
               from a in Foreman.Audit.Event,
                 where: a.subject_id == ^env and a.action == "environment.create"
             )

    assert actor_id == ctx.user.id
    Repo.update!(change(ctx.repo, default_branch: "trunk"))
    Registry.unregister(Foreman.Registry, {:agent, box})
    assert {:ok, ^env, ^op} = Mutations.create(ctx.actor, "first", ctx.input)

    assert {:error, :idempotency_conflict, _} =
             Mutations.create(ctx.actor, "first", Map.put(ctx.input, "branch", "main"))

    assert {:ok, other, _} = Mutations.create(ctx.actor, "second", ctx.input)
    assert %{box_id: id, branch: "trunk"} = Repo.get!(Environment, other)
    assert id == shared.id
    refute other == env
  end

  test "explicit errors, no partial reservation and warning-only automatic placement", ctx do
    input = Map.put(ctx.input, "box_id", ctx.box.id)
    assert {:error, :box_offline, _} = Mutations.create(ctx.actor, "key", input)

    assert {:error, :resource_not_found, _} =
             Mutations.create(ctx.actor, "key", %{input | "box_id" => Ecto.UUID.generate()})

    assert {:error, :no_provisionable_boxes, _} = Mutations.create(ctx.actor, "key", ctx.input)
    online(ctx.box)
    Repo.update!(change(ctx.box, vm: nil))
    assert {:error, :box_vm_unavailable, _} = Mutations.create(ctx.actor, "key", input)
    Repo.update!(change(ctx.box, vm: %{"ready" => false}))
    assert {:error, :box_vm_unavailable, _} = Mutations.create(ctx.actor, "key", input)
    Repo.update!(change(Repo.reload!(ctx.box), vm: %{"ready" => true}, capacity_policy: "warn"))
    Repo.update!(change(ctx.repo, cpu_limit: 30.0))
    assert {:error, :no_provisionable_boxes, _} = Mutations.create(ctx.actor, "key", ctx.input)

    assert {:error, :capacity_confirmation_required, _} =
             Mutations.create(ctx.actor, "key", input)

    Repo.update!(change(Repo.reload!(ctx.box), capacity_policy: "refuse"))

    assert {:error, :capacity_exceeded, _} =
             Mutations.create(ctx.actor, "key", Map.put(input, "confirm_capacity_warning", true))

    assert {:error, :no_provisionable_boxes, _} = Mutations.create(ctx.actor, "key", ctx.input)
    assert Repo.aggregate(Receipt, :count) == 0
    Repo.update!(change(Repo.reload!(ctx.box), capacity_policy: "warn"))

    assert {:ok, _, _} =
             Mutations.create(
               ctx.actor,
               "key",
               Map.put(ctx.input, "confirm_capacity_warning", true)
             )
  end

  test "create inputs and expiry permissions reserve nothing until accepted", ctx do
    online(ctx.box)

    for invalid <- [
          %{},
          Map.put(ctx.input, "extra", 1),
          Map.put(ctx.input, "box_id", nil),
          Map.put(ctx.input, "branch", ""),
          Map.put(ctx.input, "confirm_capacity_warning", "true"),
          Map.put(ctx.input, "expiry", %{"action" => "stop"}),
          Map.put(ctx.input, "expiry", %{"at" => "2000-01-01T00:00:00Z", "action" => "stop"})
        ] do
      assert {:error, :invalid_request, _} = Mutations.create(ctx.actor, "key", invalid)
    end

    assert {:error, :invalid_request, _} = Mutations.create(ctx.actor, "", ctx.input)
    at = DateTime.add(DateTime.utc_now(), 300)

    input =
      Map.put(ctx.input, "expiry", %{"at" => DateTime.to_iso8601(at), "action" => "destroy"})

    assert {:error, :insufficient_scope, _} =
             Mutations.create(%{ctx.actor | scopes: ["environments:create"]}, "key", input)

    assert Repo.aggregate(Receipt, :count) == 0
    assert {:ok, env_id, _} = Mutations.create(ctx.actor, "key", input)
    assert %{expiry_at: ^at, expiry_action: "destroy"} = Repo.get!(Environment, env_id)

    assert Repo.exists?(
             from j in Oban.Job,
               where: j.worker == "Foreman.Jobs.EnvironmentExpiry" and j.scheduled_at == ^at
           )
  end

  test "active transitions coalesce, opposing actions conflict, stable responses replay", ctx do
    online(ctx.box)
    assert {:ok, env, create} = Mutations.create(ctx.actor, "create", ctx.input)

    assert {:ok, ^env, ^create} =
             Mutations.operate(ctx.actor, env, "start", %{"action" => "start"})

    assert {:error, :lifecycle_conflict, _} =
             Mutations.operate(ctx.actor, env, "stop", %{"action" => "stop"})

    complete(ctx.box, create)
    assert {:ok, ^env, nil} = Mutations.operate(ctx.actor, env, "already", %{"action" => "start"})
    assert {:ok, ^env, stop} = Mutations.operate(ctx.actor, env, "stop", %{"action" => "stop"})
    complete(ctx.box, stop)
    assert {:ok, ^env, nil} = Mutations.operate(ctx.actor, env, "already", %{"action" => "start"})

    assert {:ok, ^env, destroy} =
             Mutations.operate(ctx.actor, env, "destroy", %{"action" => "destroy"})

    complete(ctx.box, destroy)
    Repo.delete_all(from o in Operation, where: o.environment_id == ^env)

    assert {:history_expired, ^env, ^destroy} =
             Mutations.operate(ctx.actor, env, "destroy", %{"action" => "destroy"})

    assert {:ok, ^env, nil} = Mutations.operate(ctx.actor, env, "again", %{"action" => "destroy"})

    assert {:error, :original_environment_gone, _} =
             Mutations.create(ctx.actor, "create", ctx.input)
  end

  test "a service can use only installation resources and owns the resulting workspace", ctx do
    alias Foreman.OAuth.ServiceAccounts
    admin = user_fixture(role: "admin")

    installer_box =
      box_fixture(owner_user_id: admin.id, vm: %{"ready" => true}, name: "a-installer")

    online(installer_box)
    online(ctx.box)

    {:ok, %{grant: grant}} =
      ServiceAccounts.register(Foreman.Scope.for_user(admin), "service", %{
        "name" => "Builds",
        "scopes" => ctx.actor.scopes,
        "repo_ids" => [ctx.repo.id],
        "box_ids" => [ctx.box.id]
      })

    {:ok, service} = Foreman.OAuth.authorize_grant(grant.id)

    assert {:error, :resource_not_found, _} =
             Mutations.create(service, "key", Map.put(ctx.input, "box_id", installer_box.id))

    assert {:ok, id, _op} = Mutations.create(service, "key", ctx.input)
    env = Repo.get!(Environment, id)
    assert env.box_id == ctx.box.id
    assert env.user_id == service.user.id
    assert env.api_grant_id == grant.id

    assert {:error, :resource_not_found, _} =
             Mutations.operate(ctx.actor, id, "stop", %{"action" => "stop"})

    Repo.update!(change(grant, box_ids: []))
    assert {:error, :resource_not_found, _} = Mutations.create(service, "key", ctx.input)
  end

  test "an owned warning or refusal falls back to a clean shared box", ctx do
    online(ctx.box)

    shared =
      box_fixture(
        owner_user_id: user_fixture().id,
        shared_user_ids: [ctx.user.id],
        vm: %{"ready" => true}
      )

    online(shared)
    Repo.update!(change(ctx.repo, cpu_limit: 30.0))

    for policy <- ~w(warn refuse) do
      Repo.update!(change(Repo.reload!(ctx.box), capacity_policy: policy))
      assert {:ok, env_id, _} = Mutations.create(ctx.actor, policy, ctx.input)
      assert Repo.get!(Environment, env_id).box_id == shared.id
    end
  end

  test "replays after live operation history expires and checks current visibility", ctx do
    online(ctx.box)
    assert {:ok, env, op} = Mutations.create(ctx.actor, "create", ctx.input)
    complete(ctx.box, op)
    Repo.delete!(Repo.get!(Operation, op))
    assert {:history_expired, ^env, ^op} = Mutations.create(ctx.actor, "create", ctx.input)
    Repo.update!(change(ctx.repo, private: true))
    assert {:error, :resource_not_found, _} = Mutations.create(ctx.actor, "create", ctx.input)
  end

  test "the persisted job survives worker exit and applies expiry after revocation and reconnection",
       ctx do
    alias Foreman.Jobs.EnvironmentExpiry
    online(ctx.box)
    deadline = DateTime.add(DateTime.utc_now(), 60)

    input =
      Map.put(ctx.input, "expiry", %{"action" => "stop", "at" => DateTime.to_iso8601(deadline)})

    assert {:ok, env, op} = Mutations.create(ctx.actor, "create", input)
    job = Repo.one!(from j in Oban.Job, where: j.worker == "Foreman.Jobs.EnvironmentExpiry")
    record = Repo.get!(Environment, env)
    Repo.update!(change(record, expiry_at: DateTime.add(DateTime.utc_now(), -1)))

    Registry.unregister(Foreman.Registry, {:agent, ctx.box.id})

    assert :ok =
             Task.async(fn -> EnvironmentExpiry.perform(Repo.reload!(job)) end) |> Task.await()

    assert {:error, :lifecycle_conflict, _} =
             Mutations.operate(ctx.actor, env, "late", %{"action" => "start"})

    complete(ctx.box, op)
    Foreman.OAuth.revoke_grant(ctx.actor.grant_id)

    assert :ok =
             Task.async(fn -> EnvironmentExpiry.perform(Repo.reload!(job)) end) |> Task.await()

    assert %{trigger: "expiry", api_grant_id: nil, status: "queued"} =
             cleanup =
             Repo.one!(
               from o in Operation, where: o.environment_id == ^env and o.action == "stop"
             )

    online(ctx.box)
    Foreman.Agents.agent_connected(Foreman.Boxes.get_box!(ctx.box.id))
    assert_receive {:dispatch, %{type: "env.stop", op_id: id}}
    assert id == cleanup.id
    complete(ctx.box, id)
    {renewed, _grant} = principal(ctx.user)

    assert {:ok, ^env, start} =
             Mutations.operate(renewed, env, "new-start", %{"action" => "start"})

    assert Repo.get!(Operation, start).action == "start"
    assert :ok = EnvironmentExpiry.perform(job)

    assert Repo.aggregate(
             from(o in Operation, where: o.environment_id == ^env and o.trigger == "expiry"),
             :count
           ) == 1
  end

  test "a completed stop policy permits a new start and never stops the restarted workspace",
       ctx do
    online(ctx.box)
    at = DateTime.add(DateTime.utc_now(), 60)
    input = Map.put(ctx.input, "expiry", %{"at" => DateTime.to_iso8601(at), "action" => "stop"})
    assert {:ok, env, create} = Mutations.create(ctx.actor, "create", input)
    complete(ctx.box, create)

    Repo.get!(Environment, env)
    |> change(expiry_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    job = Repo.one!(from j in Oban.Job, where: j.worker == "Foreman.Jobs.EnvironmentExpiry")
    assert :ok = Foreman.Jobs.EnvironmentExpiry.perform(job)
    assert_receive {:dispatch, %{type: "env.stop", op_id: cleanup}}
    complete(ctx.box, cleanup)

    assert {:ok, ^env, start} =
             Mutations.operate(ctx.actor, env, "start-again", %{"action" => "start"})

    assert_receive {:dispatch, %{type: "env.secrets.write", op_id: files}}
    complete(ctx.box, files)
    assert_receive {:dispatch, %{type: "env.start", op_id: ^start}}
    complete(ctx.box, start)
    assert Repo.get!(Environment, env).observed_state == "running"
    assert :ok = Foreman.Jobs.EnvironmentExpiry.perform(job)
    refute_received {:dispatch, %{type: "env.stop"}}
  end

  test "the receipt namespace distinguishes endpoints, clients and intended same-branch creates",
       ctx do
    alias Foreman.OAuth.{Client, Grant}
    online(ctx.box)
    assert {:ok, env, create} = Mutations.create(ctx.actor, "same", ctx.input)
    complete(ctx.box, create)
    assert {:ok, ^env, nil} = Mutations.operate(ctx.actor, env, "same", %{"action" => "start"})

    assert {:error, :idempotency_conflict, _} =
             Mutations.operate(ctx.actor, env, "same", %{"action" => "stop"})

    repo = ctx.repo
    assert {:ok, second, _} = Mutations.create(ctx.actor, "second", ctx.input)
    assert Repo.get!(Environment, second).branch == repo.default_branch
    refute second == env

    client = Repo.insert!(%Client{id: "other-app", name: "Other App", kind: "public"})

    grant =
      Repo.insert!(%Grant{user_id: ctx.user.id, client_id: client.id, scopes: ctx.actor.scopes})

    {:ok, other} = Foreman.OAuth.authorize_grant(grant.id)
    assert {:ok, third, _} = Mutations.create(other, "same", ctx.input)
    refute third in [env, second]
  end

  test "the original expiry can be replayed after its deadline in an equivalent timezone", ctx do
    online(ctx.box)
    at = DateTime.add(DateTime.utc_now(), 2)
    input = Map.put(ctx.input, "expiry", %{"at" => DateTime.to_iso8601(at), "action" => "stop"})
    assert {:ok, env, op} = Mutations.create(ctx.actor, "expiry", input)
    Process.sleep(max(1, DateTime.diff(at, DateTime.utc_now(), :millisecond) + 1))
    replay = put_in(input, ["expiry", "at"], DateTime.to_iso8601(at, :extended, 3600))
    assert {:ok, ^env, ^op} = Mutations.create(ctx.actor, "expiry", replay)
    assert {:error, :invalid_request, _} = Mutations.create(ctx.actor, "new-key", replay)
  end

  test "a new socket must establish current state before saving a stable receipt", ctx do
    env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
    online(ctx.box)

    Foreman.Agents.handle_event(ctx.box.id, %ForemanProtocol.Event{
      type: "box.inventory",
      payload: %{environments: [%{env_id: env.id, slug: env.slug, state: "running"}]}
    })

    assert {:ok, _, nil} =
             Mutations.operate(ctx.actor, env.id, "confirmed", %{"action" => "start"})

    Registry.unregister(Foreman.Registry, {:agent, ctx.box.id})
    parent = self()

    channel =
      spawn_link(fn ->
        Foreman.Agents.register(ctx.box.id)
        send(parent, :joined)

        receive do
          :close -> :ok
        end
      end)

    on_exit(fn -> send(channel, :close) end)
    assert_receive :joined

    assert {:ok, _, op_id} =
             Mutations.operate(ctx.actor, env.id, "reconnected", %{"action" => "start"})

    assert is_binary(op_id)
    assert Repo.get!(Operation, op_id).action == "start"
  end

  test "buffered pre-join inventory cannot confirm a no-op until a fresh round trip", ctx do
    env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
    :ok = Foreman.Agents.register(ctx.box.id)
    entries = [%{env_id: env.id, slug: env.slug, state: "running"}]
    {:ok, inventory} = ForemanProtocol.Event.new("box.inventory", %{environments: entries})
    :ok = Foreman.Agents.handle_event(ctx.box.id, inventory)
    refute Foreman.Agents.LifecycleState.confirmed?(env, "running")
    assert_receive {:dispatch, %{type: "box.inventory", op_id: probe}}

    {:ok, buffered} = ForemanProtocol.Event.new("env.state", %{env_id: env.id, state: "running"})
    :ok = Foreman.Agents.handle_event(ctx.box.id, buffered)
    :ok = Foreman.Agents.handle_event(ctx.box.id, inventory)
    refute_received {:dispatch, _}
    refute Foreman.Agents.LifecycleState.confirmed?(env, "running")

    {:ok, failed} = ForemanProtocol.Event.new("op.result", %{op_id: probe, status: "error"})
    :ok = Foreman.Agents.handle_event(ctx.box.id, failed)
    :ok = Foreman.Agents.handle_event(ctx.box.id, inventory)
    assert_receive {:dispatch, %{type: "box.inventory", op_id: retry}}
    refute Foreman.Agents.LifecycleState.confirmed?(env, "running")

    {:ok, result} =
      ForemanProtocol.Event.new("op.result", %{
        op_id: retry,
        status: "ok",
        result: ForemanProtocol.Event.to_wire(inventory)["payload"]
      })

    :ok = Foreman.Agents.handle_event(ctx.box.id, result)

    assert {:ok, _, nil} =
             Mutations.operate(ctx.actor, env.id, "verified", %{"action" => "start"})
  end

  test "a queued start of an errored workspace reserves its boot allocation", ctx do
    online(ctx.box)

    Repo.update!(
      change(ctx.box, capacity_policy: "refuse", capacity: %{"cpus" => 2}, cpu_threshold: 1.0)
    )

    repo = Repo.update!(change(ctx.repo, cpu_limit: 2.0))
    env = environment_fixture(user: ctx.user, repo: repo, box: ctx.box, observed_state: "error")

    assert {:ok, _, start} =
             Mutations.operate(ctx.actor, env.id, "recover", %{"action" => "start"})

    assert Repo.get!(Operation, start).status == "queued"
    assert Enum.map(Foreman.Environments.live_for_box(ctx.box.id), & &1.boot_reserved) == [true]

    assert {:error, :capacity_exceeded, _} =
             Mutations.create(ctx.actor, "competitor", Map.put(ctx.input, "box_id", ctx.box.id))

    assert Repo.aggregate(from(e in Environment, where: e.box_id == ^ctx.box.id), :count) == 1
  end

  defp complete(box, op_id) do
    {:ok, result} =
      ForemanProtocol.Event.new("op.result", %{op_id: op_id, status: "ok", result: %{}})

    assert :ok = Foreman.Agents.handle_event(box.id, result)
  end
end
