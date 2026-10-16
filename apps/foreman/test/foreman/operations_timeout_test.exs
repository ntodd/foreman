defmodule Foreman.OperationsTimeoutTest do
  @moduledoc """
  Housekeeping fails operations that never report back, and a real result
  arriving later still wins, once. Neither may overwrite the other out of
  order.
  """
  use Foreman.DataCase

  alias Foreman.{Agents, Environments, Operations, Scope}
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    env = environment_fixture(user: user, repo: repo, box: box)
    env = Repo.update!(Ecto.Changeset.change(env, observed_state: "stopped"))
    %{box: box, env: env, scope: Scope.for_user(user)}
  end

  defp report(box, op_id, payload) do
    {:ok, ev} = Event.new("op.result", Map.put(payload, :op_id, op_id))
    Agents.handle_event(box.id, ev)
  end

  defp start(ctx) do
    {:ok, _} = Environments.start(ctx.scope, ctx.env)

    # A start goes out behind a secrets write.
    assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
    :ok = report(ctx.box, write.op_id, %{status: "ok"})
    assert_receive {:dispatch, %Command{type: "env.start"} = start}
    Operations.get!(start.op_id)
  end

  test "a late failure is applied once; redelivered, it doesn't undo what came after", ctx do
    op = start(ctx)
    {:ok, op} = Operations.timed_out(op, "no result after 3 hours")
    Environments.apply_result(op)

    :ok = report(ctx.box, op.id, %{status: "error", error: "boom"})
    assert %{status: "failed", error: "boom"} = Operations.get!(op.id)
    refute Operations.get!(op.id).args["timed_out"]

    env = Environments.update_env!(Repo.reload!(ctx.env), %{observed_state: "running"})

    :ok = report(ctx.box, op.id, %{status: "error", error: "boom"})
    assert Repo.reload!(env).observed_state == "running"
  end

  test "a timeout and its effect on the environment are written together", ctx do
    op = start(ctx)

    assert_raise RuntimeError, fn ->
      Operations.timed_out(op, "no result after 3 hours", fn _op -> raise "boom" end)
    end

    # Nothing half-done for a real result to land in between.
    assert Operations.get!(op.id).status == op.status

    assert {:ok, failed, env} =
             Operations.timed_out(op, "no result after 3 hours", &Environments.record_result/1)

    assert failed.status == "failed"
    assert env.id == ctx.env.id
    assert Operations.timed_out(op, "again", &Environments.record_result/1) == :finished
  end

  test "a late success clears the timeout", ctx do
    op = start(ctx)
    {:ok, op} = Operations.timed_out(op, "no result after 3 hours")
    Environments.apply_result(op)

    :ok = report(ctx.box, op.id, %{status: "ok"})
    op = Operations.get!(op.id)
    assert op.status == "succeeded"
    refute op.args["timed_out"]
  end

  test "giving up doesn't overwrite a result that landed after the operation was read", ctx do
    stale = start(ctx)
    :ok = report(ctx.box, stale.id, %{status: "error", error: "cancelled"})

    assert Operations.timed_out(stale, "no result after 3 hours") == :finished
    assert Operations.get!(stale.id).status == "cancelled"
  end
end
