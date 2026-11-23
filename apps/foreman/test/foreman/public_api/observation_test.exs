defmodule Foreman.PublicAPI.ObservationTest do
  use Foreman.DataCase

  alias Foreman.{Agents, Environments, Operations}
  alias Foreman.Operations.LogStore
  alias Foreman.PublicAPI.Readiness
  alias ForemanProtocol.Event

  test "readiness follows the container that completed setup, including partially running projects" do
    env = environment_fixture()
    :ok = Agents.register(env.box_id)
    setup_id = String.duplicate("a", 64)
    sidecar_id = String.duplicate("b", 64)

    op =
      Operations.create!(%{
        environment_id: env.id,
        box_id: env.box_id,
        action: "create",
        command: "env.create",
        status: "succeeded",
        result: %{"container_id" => setup_id},
        finished_at: DateTime.utc_now()
      })

    env = Environments.record_result(op)
    assert Readiness.get(env) == "unknown"

    assert :ok = sample(env, [setup_id])
    assert Readiness.get(env) == "ready"
    assert :ok = sample(env, [sidecar_id])
    assert Readiness.get(env) == "not_ready"
    # No observation for the guest, even though its box remains connected.
    assert :ok = sample(env, nil)
    assert Readiness.get(env) == "unknown"

    assert :ok = sample(env, [setup_id])
    failed = Environments.record_result(%{op | status: "failed", error: "postCreate failed"})
    assert Readiness.get(failed) == "not_ready"
    Registry.unregister(Foreman.Registry, {:agent, env.box_id})
    assert Readiness.get(env) == "unknown"
    :ok = Agents.register(env.box_id)
    assert Readiness.get(env) == "unknown"
  end

  test "a replaced workspace requires the successful restart's new ID and resume preserves it" do
    env = environment_fixture() |> change(workspace_container_id: "original") |> Repo.update!()
    :ok = Agents.register(env.box_id)

    for action <- ["restart_all", "restart_affected"] do
      op =
        Operations.create!(%{
          environment_id: env.id,
          box_id: env.box_id,
          action: action,
          command: "env.restart",
          status: "succeeded",
          result: %{"container_id" => "new"}
        })

      after_restart = Environments.record_result(op)
      assert :ok = sample(env, ["sidecar"])
      assert Readiness.get(after_restart) == "not_ready"
      assert :ok = sample(env, ["new", "sidecar"])
      assert Readiness.get(after_restart) == "ready"

      assert Readiness.get(
               Environments.record_result(%{op | action: "start", result: %{"resumed" => true}})
             ) == "ready"

      old_agent = Environments.record_result(%{op | result: %{}})
      assert Readiness.get(old_agent) == "unknown"
    end
  end

  test "an inventory scan more than a minute old cannot refresh readiness on receipt" do
    env = environment_fixture(created_once: true, observed_state: "running")
    env = Repo.update!(change(env, workspace_container_id: "workspace"))
    :ok = Agents.register(env.box_id)

    Registry.update_value(Foreman.Registry, {:agent, env.box_id}, fn {joined, table} ->
      {joined - 61_000, table}
    end)

    assert :ok = sample(env, ["workspace"], 0)
    assert Readiness.get(env) == "unknown"
    assert :ok = sample(env, ["workspace"], 61_000)
    assert Readiness.get(env) == "ready"
  end

  defp sample(env, running, since_join_ms \\ 0) do
    entries = if running, do: %{env.id => running}, else: %{}

    {:ok, event} =
      Event.new("box.workspaces", %{since_join_ms: since_join_ms, environments: entries})

    Agents.handle_event(env.box_id, event)
  end

  test "housekeeping ages logs and history from completion, including for destroyed environments" do
    env = environment_fixture(destroyed_at: DateTime.utc_now())
    now = DateTime.utc_now()
    old = DateTime.add(now, -100, :day)

    operations =
      for {status, finished} <- [
            {"running", nil},
            {"succeeded", DateTime.add(now, -29, :day)},
            {"succeeded", DateTime.add(now, -31, :day)},
            {"failed", DateTime.add(now, -91, :day)}
          ] do
        op =
          Operations.create!(%{
            environment_id: env.id,
            box_id: env.box_id,
            action: "create",
            command: "env.create",
            status: status,
            inserted_at: old,
            finished_at: finished
          })

        LogStore.append(op.id, "log")
        op
      end

    assert :ok = Foreman.Jobs.Housekeeping.perform(%{})
    [running, recent, history, expired] = operations
    for op <- [running, recent], do: assert({"log", 3, false} == LogStore.page(op, 0))
    assert {"", 0, false} = LogStore.page(history, 0)
    assert Operations.get(history.id)
    refute Operations.get(expired.id)
    assert Repo.reload!(env).destroyed_at
  end

  test "log offsets survive legacy conversion, UTF-8 page boundaries, and loss of the old tail" do
    env = environment_fixture()

    op =
      Operations.create!(%{
        environment_id: env.id,
        box_id: env.box_id,
        action: "create",
        command: "env.create",
        log: "old\n"
      })

    assert {"old\n", 4, false} = LogStore.page(op, 0)
    text = String.duplicate("x", 65_535) <> "━\n"
    LogStore.append(op.id, text)
    assert {page, next, false} = LogStore.page(op, 4)
    assert String.valid?(page)
    assert {rest, last, false} = LogStore.page(op, next)
    assert page <> rest == text
    assert {"", ^last, false} = LogStore.page(op, last)

    LogStore.append(op.id, String.duplicate("z", 1_048_580))
    assert {retained, pos, true} = LogStore.page(op, 4)
    assert retained == String.duplicate("z", 65_536)
    assert {_, _, false} = LogStore.page(op, pos)
  end
end
