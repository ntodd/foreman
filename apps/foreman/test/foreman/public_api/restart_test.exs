defmodule Foreman.PublicAPI.RestartTest do
  @moduledoc "Restarting a running environment's services through the public API."
  use Foreman.DataCase

  import Foreman.PublicAPIMutationFixtures
  setup :local_git

  alias Foreman.Operations.Operation
  alias Foreman.PublicAPI.Mutations

  setup do
    user = user_fixture()
    repo = repo_fixture() |> change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    {actor, _} = principal(user)
    env = environment_fixture(user: user, repo: repo, box: box)
    %{actor: actor, user: user, repo: repo, box: box, env: env}
  end

  defp pending(env, names),
    do: env |> change(pending_restart: names != [], pending_changes: names) |> Repo.update!()

  defp restart(actor, env, action, key \\ nil),
    do: Mutations.operate(actor, env.id, key || action, %{"action" => action})

  test "restart_all queues a restart of every service, attributed to the connection", ctx do
    env_id = ctx.env.id
    grant = ctx.actor.grant_id

    assert {:ok, ^env_id, op_id} = restart(ctx.actor, ctx.env, "restart_all")

    assert %Operation{action: "restart_all", api_grant_id: ^grant, status: "queued"} =
             Repo.get!(Operation, op_id)

    assert Repo.reload!(ctx.env).desired_state == "running"

    assert %{metadata: %{"client_id" => "foreman-cli"}} =
             Enum.find(Foreman.Audit.recent(), &(&1.action == "environment.restart_all"))

    # The same key replays the same operation; a new key follows the one in flight.
    assert {:ok, ^env_id, ^op_id} = restart(ctx.actor, ctx.env, "restart_all")
    assert {:ok, ^env_id, ^op_id} = restart(ctx.actor, ctx.env, "restart_all", "second key")
    assert Repo.aggregate(from(o in Operation, where: o.action == "restart_all"), :count) == 1
  end

  test "restart_affected restarts what the changed secrets touch, and nothing when none have",
       ctx do
    env_id = ctx.env.id

    assert {:ok, ^env_id, nil} =
             restart(ctx.actor, ctx.env, "restart_affected", "nothing pending")

    refute Repo.exists?(from o in Operation, where: o.action == "restart_affected")

    pending(ctx.env, ["API_KEY", "DATABASE_URL"])

    assert {:ok, ^env_id, op_id} = restart(ctx.actor, ctx.env, "restart_affected", "now pending")

    assert %Operation{action: "restart_affected", args: %{"changed" => changed}} =
             Repo.get!(Operation, op_id)

    assert changed == ["API_KEY", "DATABASE_URL"]
  end

  test "an environment that isn't running conflicts, and says to start it", ctx do
    ctx.env |> change(desired_state: "stopped", observed_state: "stopped") |> Repo.update!()

    for action <- ~w(restart_all restart_affected) do
      assert {:error, :lifecycle_conflict, message} = restart(ctx.actor, ctx.env, action)
      assert message =~ "start"
    end

    refute Repo.exists?(from o in Operation, where: o.action in ~w(restart_all restart_affected))
  end

  test "another transition in flight conflicts in both directions", ctx do
    env_id = ctx.env.id
    pending(ctx.env, ["A"])

    assert {:ok, ^env_id, _op} = restart(ctx.actor, ctx.env, "restart_affected")
    assert {:error, :lifecycle_conflict, _} = restart(ctx.actor, ctx.env, "restart_all")

    assert {:error, :lifecycle_conflict, _} =
             Mutations.operate(ctx.actor, env_id, "stop", %{"action" => "stop"})
  end

  test "a restart during a start conflicts, where a second start would follow it", ctx do
    env = ctx.env |> change(desired_state: "stopped", observed_state: "stopped") |> Repo.update!()
    Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    assert {:ok, _, start} = Mutations.operate(ctx.actor, env.id, "start", %{"action" => "start"})
    assert is_binary(start)

    assert {:error, :lifecycle_conflict, _} = restart(ctx.actor, env, "restart_all")
  end

  test "a restart takes permission to both stop and start", ctx do
    for scopes <- [["environments:start"], ["environments:stop"], ["environments:create"]] do
      {limited, _} = principal(ctx.user, scopes)
      assert {:error, :insufficient_scope, _} = restart(limited, ctx.env, "restart_all")
    end

    {both, _} = principal(ctx.user, ~w(environments:start environments:stop))
    assert {:ok, _, op} = restart(both, ctx.env, "restart_all")
    assert is_binary(op)
  end

  test "someone else's environment is not found, and unknown actions are invalid", ctx do
    {stranger, _} = principal(user_fixture())
    assert {:error, :resource_not_found, _} = restart(stranger, ctx.env, "restart_all")

    for action <- ~w(restart suspend rebuild) do
      assert {:error, :invalid_request, _} = restart(ctx.actor, ctx.env, action)
    end
  end
end
