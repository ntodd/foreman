defmodule Foreman.EnvironmentsSuspendTest do
  @moduledoc """
  Suspend: an environment's VM saved to disk and stopped, resumed by a
  start where it left off.
  """
  use Foreman.DataCase

  alias Foreman.{Agents, Environments, Scope}
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    scope = Scope.for_user(user)

    {:ok, env} =
      Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

    assert_receive {:dispatch, %Command{type: "env.create"} = create}
    report(box, create, %{status: "ok", result: %{"services" => ["app"]}})
    %{scope: scope, box: box, env: Repo.reload!(env)}
  end

  defp report(box, cmd, payload) do
    {:ok, ev} = Event.new("op.result", Map.put(payload, :op_id, cmd.op_id))
    :ok = Agents.handle_event(box.id, ev)
  end

  test "suspend sends env.suspend and leaves the environment suspended", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend", payload: payload} = cmd}
    assert payload == %{env_id: ctx.env.id, slug: ctx.env.slug}

    env = Repo.reload!(ctx.env)
    assert env.observed_state == "suspending"
    # Nothing starts it again but a start.
    assert env.desired_state == "stopped"

    report(ctx.box, cmd, %{status: "ok"})
    assert Repo.reload!(ctx.env).observed_state == "suspended"
  end

  test "a failed suspend goes back to running, with the error shown", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend"} = cmd}
    report(ctx.box, cmd, %{status: "error", error: "no room for the snapshot"})

    env = Repo.reload!(ctx.env)
    assert env.observed_state == "running"
    assert env.status_message == "suspend failed: no room for the snapshot"
  end

  test "a start resumes it", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend"} = cmd}
    report(ctx.box, cmd, %{status: "ok"})

    {:ok, _} = Environments.start(ctx.scope, Repo.reload!(ctx.env))
    # Secrets first, as for any start.
    assert_receive {:dispatch, %Command{type: "env.secrets.write"} = secrets}
    report(ctx.box, secrets, %{status: "ok"})
    assert_receive {:dispatch, %Command{type: "env.start"}}
    assert Repo.reload!(ctx.env).desired_state == "running"
  end

  test "a start after a suspend wins: the last click counts", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    {:ok, start} = Environments.start(ctx.scope, Repo.reload!(ctx.env))
    assert Repo.reload!(start).status in ["queued", "dispatched"]
    assert Repo.reload!(ctx.env).desired_state == "running"
  end

  test "reconcile leaves a suspended environment alone, unless it should be running", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend"} = cmd}
    report(ctx.box, cmd, %{status: "ok"})

    inventory = [%{env_id: ctx.env.id, slug: ctx.env.slug, state: "suspended", containers: []}]
    Environments.reconcile_inventory(ctx.box.id, inventory)
    refute_receive {:dispatch, %Command{type: "env.start"}}, 200

    Repo.reload!(ctx.env) |> Ecto.Changeset.change(desired_state: "running") |> Repo.update!()
    Environments.reconcile_inventory(ctx.box.id, inventory)
    assert_receive {:dispatch, %Command{type: "env.secrets.write"} = secrets}
    report(ctx.box, secrets, %{status: "ok"})
    assert_receive {:dispatch, %Command{type: "env.start"}}
  end
end
