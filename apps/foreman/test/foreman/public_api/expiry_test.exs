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

  test "an in-flight lifecycle transition finishes before the expiry is accepted" do
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
    assert {:snooze, seconds} = EnvironmentExpiry.perform(job)
    assert seconds > 0
    assert [^op] = Repo.all(from o in Operation, where: o.environment_id == ^env.id)
  end
end
