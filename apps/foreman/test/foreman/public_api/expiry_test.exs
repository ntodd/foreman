defmodule Foreman.PublicAPI.ExpiryTest do
  use Foreman.DataCase

  alias Foreman.Environments.Environment
  alias Foreman.Jobs.EnvironmentExpiry
  alias Foreman.Operations.Operation

  test "a due policy survives a worker restart, queues offline once and dispatches on reconnect" do
    for action <- ~w(stop destroy) do
      env = environment_fixture()
      due = DateTime.add(DateTime.utc_now(), -1)

      env
      |> change(expiry_at: due, expiry_action: action)
      |> Repo.update!()

      job = %Oban.Job{args: %{"environment_id" => env.id}}
      assert :ok = EnvironmentExpiry.perform(job)
      assert :ok = EnvironmentExpiry.perform(job)

      assert [%{action: ^action, trigger: "expiry", status: "queued", user_id: nil} = op] =
               Repo.all(from o in Operation, where: o.environment_id == ^env.id)

      Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)
      Foreman.Agents.agent_connected(Foreman.Boxes.get_box!(env.box_id))
      assert_receive {:dispatch, %{op_id: id, type: type}}
      assert id == op.id
      assert type == "env." <> action

      {:ok, result} =
        ForemanProtocol.Event.new("op.result", %{op_id: id, status: "ok", result: %{}})

      assert :ok = Foreman.Agents.handle_event(env.box_id, result)
      updated = Repo.get!(Environment, env.id)
      assert updated.expiry_consumed_at
      assert updated.observed_state == if(action == "stop", do: "stopped", else: "destroyed")
      assert :ok = EnvironmentExpiry.perform(job)
      assert Repo.aggregate(from(o in Operation, where: o.environment_id == ^env.id), :count) == 1
    end
  end

  test "dashboard commands cannot supersede a due policy or forget a pending physical deletion" do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, box: box)
    scope = Foreman.Scope.for_user(user)

    env
    |> change(expiry_at: DateTime.add(DateTime.utc_now(), -1), expiry_action: "destroy")
    |> Repo.update!()

    assert {:error, _} = Foreman.Environments.start(scope, env)
    assert :ok = EnvironmentExpiry.perform(%Oban.Job{args: %{"environment_id" => env.id}})
    Repo.update!(change(box, revoked_at: DateTime.utc_now()))
    assert {:error, _} = Foreman.Environments.destroy(scope, env)
    assert is_nil(Repo.reload!(env).destroyed_at)

    assert [%{action: "destroy", trigger: "expiry", status: "queued"}] =
             Repo.all(from o in Operation, where: o.environment_id == ^env.id)
  end

  test "due stop supersedes unsent boots, even if reconnect dispatch precedes Oban" do
    for action <- ~w(create start rebuild pull_rebuild restart_all restart_affected) do
      env = environment_fixture()
      boot = Foreman.Environments.queue_operation(env, action, %{}, nil)

      Repo.update!(
        change(env, expiry_at: DateTime.add(DateTime.utc_now(), -1), expiry_action: "stop")
      )

      Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)

      Foreman.Agents.agent_connected(Foreman.Boxes.get_box!(env.box_id))
      assert_receive {:dispatch, %{type: "env.stop", op_id: cleanup}}
      assert Repo.get!(Operation, cleanup).trigger == "expiry"
      assert Repo.reload!(boot).status == "cancelled"

      assert {:error, _} =
               Foreman.Environments.retry(
                 Foreman.Scope.for_user(Repo.preload(env, :user).user),
                 env
               )
    end
  end

  test "failed physical expiry retains the policy and durably retries with its system identity" do
    for action <- ~w(stop destroy) do
      env = environment_fixture()

      Repo.update!(
        change(env, expiry_at: DateTime.add(DateTime.utc_now(), -1), expiry_action: action)
      )

      Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)
      job = %Oban.Job{args: %{"environment_id" => env.id}}
      assert :ok = EnvironmentExpiry.perform(job)
      assert_receive {:dispatch, %{op_id: first}}

      {:ok, failure} =
        ForemanProtocol.Event.new("op.result", %{
          op_id: first,
          status: "error",
          error: "disk busy"
        })

      assert :ok = Foreman.Agents.handle_event(env.box_id, failure)
      assert is_nil(Repo.reload!(env).expiry_consumed_at)
      assert is_nil(Repo.reload!(env).destroyed_at)
      assert Repo.get!(Operation, first).status == "failed"

      Registry.unregister(Foreman.Registry, {:agent, env.box_id})

      retry_job =
        Repo.one!(
          from j in Oban.Job,
            where:
              j.worker == "Foreman.Jobs.EnvironmentExpiry" and j.args["environment_id"] == ^env.id
        )

      assert :ok = EnvironmentExpiry.perform(retry_job)
      assert :ok = EnvironmentExpiry.perform(retry_job)

      retry =
        Repo.one!(
          from o in Operation, where: o.environment_id == ^env.id and o.status == "queued"
        )

      assert retry.action == action and retry.trigger == "expiry" and retry.user_id == nil
      Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)
      Foreman.Agents.agent_connected(Foreman.Boxes.get_box!(env.box_id))
      assert_receive {:dispatch, %{op_id: second}}
      assert second == retry.id

      {:ok, success} =
        ForemanProtocol.Event.new("op.result", %{op_id: second, status: "ok", result: %{}})

      assert :ok = Foreman.Agents.handle_event(env.box_id, success)
      assert Repo.reload!(env).expiry_consumed_at
      assert :ok = EnvironmentExpiry.perform(retry_job)
      assert Repo.aggregate(from(o in Operation, where: o.environment_id == ^env.id), :count) == 2
    end
  end

  test "a late physical stop result retires its queued retry" do
    env = environment_fixture()
    Repo.update!(change(env, expiry_at: DateTime.add(DateTime.utc_now(), -1), expiry_action: "stop"))
    Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)
    job = %Oban.Job{args: %{"environment_id" => env.id}}
    :ok = EnvironmentExpiry.perform(job)
    assert_receive {:dispatch, %{op_id: first}}
    {:ok, _, _} = Foreman.Operations.timed_out(Repo.get!(Operation, first), "timed out", &Foreman.Environments.record_result/1)
    Registry.unregister(Foreman.Registry, {:agent, env.box_id})
    :ok = EnvironmentExpiry.perform(job)
    {:ok, result} = ForemanProtocol.Event.new("op.result", %{op_id: first, status: "ok", result: %{}})
    :ok = Foreman.Agents.handle_event(env.box_id, result)
    assert Repo.reload!(env).expiry_consumed_at
    refute Repo.exists?(from o in Operation, where: o.environment_id == ^env.id and o.status == "queued")
  end

  test "start can provision an initial create that expiry stopped before first dispatch" do
    env = environment_fixture(created_once: false, observed_state: "pending")
    Foreman.Environments.queue_operation(env, "create", %{}, nil)
    Repo.update!(change(env, expiry_at: DateTime.add(DateTime.utc_now(), -1), expiry_action: "stop"))
    Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)
    :ok = EnvironmentExpiry.perform(%Oban.Job{args: %{"environment_id" => env.id}})
    assert_receive {:dispatch, %{type: "env.stop", op_id: stop}}
    {:ok, result} = ForemanProtocol.Event.new("op.result", %{op_id: stop, status: "ok", result: %{}})
    :ok = Foreman.Agents.handle_event(env.box_id, result)
    scope = Foreman.Scope.for_user(Repo.preload(env, :user).user)
    {:ok, start} = Foreman.Environments.start(scope, Repo.reload!(env))
    assert start.action == "start"
    assert start.command == "env.create"
    assert_receive {:dispatch, %{type: "env.create", op_id: boot}}
    assert boot == start.id
  end

  test "a pending expiry is visible while the in-flight transition finishes" do
    env = environment_fixture()

    env
    |> change(expiry_at: DateTime.add(DateTime.utc_now(), -1), expiry_action: "stop")
    |> Repo.update!()

    op =
      Foreman.Operations.create!(%{
        environment_id: env.id,
        box_id: env.box_id,
        action: "create",
        command: "env.create",
        status: "dispatched"
      })

    job = %Oban.Job{args: %{"environment_id" => env.id}}
    Registry.register(Foreman.Registry, {:agent, env.box_id}, nil)
    assert :ok = EnvironmentExpiry.perform(job)

    assert %{status: "queued", trigger: "expiry", id: cleanup} =
             Repo.one!(
               from o in Operation, where: o.environment_id == ^env.id and o.action == "stop"
             )

    refute_received {:dispatch, _}

    {:ok, event} =
      ForemanProtocol.Event.new("op.result", %{op_id: op.id, status: "ok", result: %{}})

    assert :ok = Foreman.Agents.handle_event(env.box_id, event)
    assert_receive {:dispatch, %{type: "env.stop", op_id: ^cleanup}}
  end
end
