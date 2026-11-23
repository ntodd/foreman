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
    box = box_fixture(owner_user_id: user.id)
    {actor, _} = principal(user)
    %{actor: actor, user: user, repo: repo, box: box, input: %{"repo_id" => repo.id}}
  end

  defp online(box), do: Registry.register(Foreman.Registry, {:agent, box.id}, nil)

  test "placement, replay, changed defaults, attribution and a fresh key", ctx do
    online(ctx.box)

    shared =
      box_fixture(
        name: "a-shared",
        owner_user_id: user_fixture().id,
        shared_user_ids: [ctx.user.id]
      )

    online(shared)
    assert {:ok, env, op} = Mutations.create(ctx.actor, "first", ctx.input)
    assert %{box_id: box, branch: "main", api_grant_id: grant} = Repo.get!(Environment, env)
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
    Repo.update!(change(ctx.box, vm: %{"ready" => false}))
    assert {:error, :box_vm_unavailable, _} = Mutations.create(ctx.actor, "key", input)
    Repo.update!(change(Repo.reload!(ctx.box), vm: nil, capacity_policy: "warn"))
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

    assert {:ok, ^env, ^destroy} =
             Mutations.operate(ctx.actor, env, "destroy", %{"action" => "destroy"})

    assert {:ok, ^env, nil} = Mutations.operate(ctx.actor, env, "again", %{"action" => "destroy"})

    assert {:error, :original_environment_gone, _} =
             Mutations.create(ctx.actor, "create", ctx.input)
  end

  defp complete(box, op_id) do
    {:ok, result} =
      ForemanProtocol.Event.new("op.result", %{op_id: op_id, status: "ok", result: %{}})

    assert :ok = Foreman.Agents.handle_event(box.id, result)
  end
end
