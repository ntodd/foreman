defmodule Foreman.EnvironmentsLifecycleTest do
  @moduledoc """
  The environment state machine under failure: failed and cancelled
  operations, late and malformed results, queue ordering, and boxes that
  are gone for good.
  """
  use Foreman.DataCase

  alias Foreman.{Agents, Boxes, Environments, Operations, Scope, Secrets}
  alias Foreman.Environments.Environment
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    %{user: user, repo: repo, box: box, scope: Scope.for_user(user)}
  end

  @up_result %{
    "remote_user" => "vscode",
    "remote_workspace_folder" => "/workspaces/storefront",
    "services" => ["app", "db"],
    "devcontainer_service" => "app"
  }

  defp connect_agent(box),
    do: {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

  defp disconnect_agent(box), do: Registry.unregister(Foreman.Registry, {:agent, box.id})

  defp report(box, cmd, payload) do
    {:ok, ev} = Event.new("op.result", Map.put(payload, :op_id, cmd.op_id))
    Agents.handle_event(box.id, ev)
  end

  defp succeed(box, cmd, result \\ %{}),
    do: :ok = report(box, cmd, %{status: "ok", result: result})

  defp running_env(ctx) do
    connect_agent(ctx.box)

    {:ok, env} =
      Environments.create_environment(ctx.scope, %{
        "repo_id" => ctx.repo.id,
        "box_id" => ctx.box.id
      })

    assert_receive {:dispatch, %Command{type: "env.create"} = create}
    succeed(ctx.box, create, @up_result)
    Repo.reload!(env)
  end

  describe "failed and cancelled stop and destroy" do
    test "a stop sent before this version, which doesn't record the state it left, fails back to running",
         ctx do
      connect_agent(ctx.box)
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)

      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      op = Operations.get!(stop.op_id)
      Repo.update!(Ecto.Changeset.change(op, args: Map.delete(op.args, "prior_state")))

      :ok = report(ctx.box, stop, %{status: "error", error: "compose hung"})
      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.status_message =~ "stop failed"

      # Not an error state: what the box reports next still counts.
      Environments.reconcile_inventory(ctx.box.id, [
        %{env_id: env.id, slug: env.slug, state: "stopped", containers: []}
      ])

      assert Repo.reload!(env).observed_state == "stopped"
    end

    test "a failed stop goes back to the state it left, with the error shown", ctx do
      connect_agent(ctx.box)
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)

      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      assert Repo.reload!(env).observed_state == "stopping"

      :ok = report(ctx.box, stop, %{status: "error", error: "docker compose stop timed out"})

      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.status_message =~ "stop failed: docker compose stop timed out"
    end

    test "a failed destroy goes back to the state it left", ctx do
      connect_agent(ctx.box)

      env =
        environment_fixture(
          user: ctx.user,
          repo: ctx.repo,
          box: ctx.box,
          observed_state: "stopped"
        )

      {:ok, _} = Environments.destroy(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.destroy"} = destroy}
      :ok = report(ctx.box, destroy, %{status: "error", error: "volume in use"})

      env = Repo.reload!(env)
      assert env.observed_state == "stopped"
      assert env.status_message =~ "destroy failed: volume in use"
      assert is_nil(env.destroyed_at)
    end

    test "cancelling a running stop restores the state and the wish to keep it running", ctx do
      connect_agent(ctx.box)
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)

      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      {:ok, _} = Environments.cancel_operation(ctx.scope, Repo.reload!(env), stop.op_id)
      assert_receive {:dispatch, %Command{type: "op.cancel"}}
      :ok = report(ctx.box, stop, %{status: "error", error: "cancelled"})

      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.desired_state == "running"
    end
  end

  describe "cancelling an operation that never left the queue" do
    test "leaves a running environment as it was", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, op} = Environments.restart(ctx.scope, env, :all)
      assert op.status == "queued"

      {:ok, _} = Environments.cancel_operation(ctx.scope, env, op.id)

      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert is_nil(env.status_message)
      assert Operations.get!(op.id).status == "cancelled"
    end

    test "undoes the desired state a queued stop set", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, op} = Environments.stop(ctx.scope, env)
      assert Repo.reload!(env).desired_state == "stopped"

      {:ok, _} = Environments.cancel_operation(ctx.scope, Repo.reload!(env), op.id)
      assert Repo.reload!(env).desired_state == "running"
    end

    test "a cancelled first create leaves the environment ready to retry", ctx do
      {:ok, env} =
        Environments.create_environment(ctx.scope, %{
          "repo_id" => ctx.repo.id,
          "box_id" => ctx.box.id
        })

      [op] = Operations.list_for_environment(env.id)
      {:ok, _} = Environments.cancel_operation(ctx.scope, env, op.id)

      env = Repo.reload!(env)
      assert env.observed_state == "error"
      refute env.created_once
    end

    test "a cancel that loses the race with dispatch doesn't overwrite the sent operation", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, op} = Environments.stop(ctx.scope, env)
      stale = Operations.get!(op.id)

      connect_agent(ctx.box)
      Agents.agent_connected(Boxes.get_box!(ctx.box.id))
      assert_receive {:dispatch, %Command{type: "env.stop"}}

      assert {:error, :not_queued} = Operations.cancel_queued(stale)
      assert Operations.get!(op.id).status == "dispatched"
    end
  end

  describe "results" do
    test "a success that arrives after Housekeeping gave up still applies", ctx do
      connect_agent(ctx.box)

      {:ok, env} =
        Environments.create_environment(ctx.scope, %{
          "repo_id" => ctx.repo.id,
          "box_id" => ctx.box.id
        })

      assert_receive {:dispatch, %Command{type: "env.create"} = create}

      Operations.get!(create.op_id)
      |> Ecto.Changeset.change(dispatched_at: DateTime.add(DateTime.utc_now(), -4 * 3600))
      |> Repo.update!()

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      assert_receive {:dispatch, %Command{type: "op.cancel"}}
      assert Repo.reload!(env).observed_state == "error"

      succeed(ctx.box, create, @up_result)

      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.created_once
      assert Operations.get!(create.op_id).status == "succeeded"
    end

    test "Housekeeping leaves operations on an offline box for the reconnect to resend", ctx do
      connect_agent(ctx.box)
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      disconnect_agent(ctx.box)

      Operations.get!(stop.op_id)
      |> Ecto.Changeset.change(dispatched_at: DateTime.add(DateTime.utc_now(), -4 * 3600))
      |> Repo.update!()

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      assert Operations.get!(stop.op_id).status == "dispatched"
    end

    test "a result the environment can't take doesn't wedge it", ctx do
      connect_agent(ctx.box)

      {:ok, env} =
        Environments.create_environment(ctx.scope, %{
          "repo_id" => ctx.repo.id,
          "box_id" => ctx.box.id
        })

      assert_receive {:dispatch, %Command{type: "env.create"} = create}

      bad =
        @up_result
        |> Map.put("host_requirements", "8 cpus please")
        |> Map.put("services", "app")
        |> Map.put("warnings", [1, 2])

      succeed(ctx.box, create, bad)

      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.created_once
      assert env.host_requirements == nil
      assert env.services == []
    end
  end

  describe "the queue" do
    test "the last action wins: stop, start, stop leaves it stopped", ctx do
      env = running_env(ctx)

      {:ok, _} = Environments.logs(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.logs"} = logs}

      {:ok, _} = Environments.stop(ctx.scope, Repo.reload!(env))
      {:ok, _} = Environments.start(ctx.scope, Repo.reload!(env))
      {:ok, _} = Environments.stop(ctx.scope, Repo.reload!(env))

      succeed(ctx.box, logs)
      sent = drain(ctx.box)

      env = Repo.reload!(env)
      assert env.desired_state == "stopped"
      assert env.observed_state == "stopped", "sent #{inspect(sent)}"
      refute "env.start" in sent
    end

    test "start after a queued stop replaces it", ctx do
      env = running_env(ctx)
      {:ok, _} = Environments.logs(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.logs"} = logs}

      {:ok, stop} = Environments.stop(ctx.scope, Repo.reload!(env))
      {:ok, _} = Environments.start(ctx.scope, Repo.reload!(env))
      assert Operations.get!(stop.id).status == "cancelled"

      succeed(ctx.box, logs)
      sent = drain(ctx.box)
      refute "env.stop" in sent
      assert Repo.reload!(env).observed_state == "running"
    end

    test "Restart affected restarts for everything changed since the last start", ctx do
      env = running_env(ctx)

      {:ok, _} = Secrets.put_secret(ctx.scope, "user", ctx.user, %{"name" => "A", "value" => "1"})
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = w1}
      succeed(ctx.box, w1)

      disconnect_agent(ctx.box)
      {:ok, _} = Environments.restart(ctx.scope, Repo.reload!(env), :affected)
      {:ok, _} = Secrets.put_secret(ctx.scope, "user", ctx.user, %{"name" => "B", "value" => "2"})

      connect_agent(ctx.box)
      Agents.agent_connected(Boxes.get_box!(ctx.box.id))
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = w2}
      succeed(ctx.box, w2)
      assert_receive {:dispatch, %Command{type: "env.restart"} = restart}
      assert Enum.sort(restart.payload.changed) == ["A", "B"]
      succeed(ctx.box, restart, @up_result)

      env = Repo.reload!(env)
      refute env.pending_restart
      assert env.pending_changes == []
    end

    test "the transitional state is recorded before the command reaches the agent", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      test = self()

      agent =
        spawn(fn ->
          {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
          send(test, :registered)

          receive do
            {:dispatch, %Command{type: "env.stop"}} ->
              send(test, {:seen, Repo.reload!(env).observed_state})
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), agent)
      assert_receive :registered
      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:seen, "stopping"}
    end
  end

  describe "pending restart" do
    test "a secret changed while a start is in flight stays pending afterwards", ctx do
      env = running_env(ctx)
      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      succeed(ctx.box, stop)

      {:ok, _} = Environments.start(ctx.scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = w}
      succeed(ctx.box, w)
      assert_receive {:dispatch, %Command{type: "env.start"} = start}

      {:ok, _} =
        Secrets.put_secret(ctx.scope, "user", ctx.user, %{"name" => "API_KEY", "value" => "new"})

      succeed(ctx.box, start, @up_result)

      env = Repo.reload!(env)
      assert env.pending_restart
      assert env.pending_changes == ["API_KEY"]
    end

    test "a secret changed during the first create is flagged and delivered", ctx do
      connect_agent(ctx.box)

      {:ok, env} =
        Environments.create_environment(ctx.scope, %{
          "repo_id" => ctx.repo.id,
          "box_id" => ctx.box.id
        })

      assert_receive {:dispatch, %Command{type: "env.create"} = create}

      {:ok, _} =
        Secrets.put_secret(ctx.scope, "user", ctx.user, %{"name" => "API_KEY", "value" => "new"})

      succeed(ctx.box, create, @up_result)

      env = Repo.reload!(env)
      assert env.pending_restart
      assert env.pending_changes == ["API_KEY"]
      assert_receive {:dispatch, %Command{type: "env.secrets.write"}}
    end
  end

  describe "a revoked box" do
    test "its environments can still be destroyed", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, logs} = Environments.logs(ctx.scope, env)
      admin = Scope.for_user(user_fixture(role: "admin"))
      {:ok, _} = Boxes.revoke(admin, Boxes.get_box!(ctx.box.id))

      {:ok, _} = Environments.destroy(ctx.scope, Repo.reload!(env))

      env = Repo.reload!(env)
      assert env.destroyed_at
      assert env.observed_state == "destroyed"
      refute env.slug in Enum.map(Environments.list_environments(ctx.scope), & &1.slug)
      assert Operations.get!(logs.id).status == "cancelled"
      refute Operations.active?(env.id)

      assert Repo.exists?(from a in Foreman.Audit.Event, where: a.action == "environment.forget")
    end
  end

  describe "slugs" do
    test "two repos with the same name on different owners both get environments", ctx do
      api = repo_fixture(owner: owner_fixture(login: "acme"), name: "api")
      other = repo_fixture(owner: owner_fixture(login: "acme-labs"), name: "api")

      assert {:ok, %{slug: "api-1"}} = create(ctx, api)
      assert {:ok, %{slug: "api-2"}} = create(ctx, other)
      assert {:ok, %{slug: "api-3"}} = create(ctx, api)
    end

    test "names that clean to the same slug share the numbering", ctx do
      assert {:ok, %{slug: "web-app-1"}} = create(ctx, repo_fixture(name: "Web_App"))
      assert {:ok, %{slug: "web-app-2"}} = create(ctx, repo_fixture(name: "web-app"))
    end

    test "another repo's longer name doesn't take a number", ctx do
      assert {:ok, %{slug: "api-v2-1"}} = create(ctx, repo_fixture(name: "api-v2"))
      assert {:ok, %{slug: "api-1"}} = create(ctx, repo_fixture(name: "api"))
    end

    test "a slug taken concurrently is a changeset error, so create retries", ctx do
      {:ok, first} = create(ctx, ctx.repo)

      loser =
        Environment.create_changeset(%Environment{}, %{
          slug: first.slug,
          index: 1,
          repo_id: ctx.repo.id,
          user_id: ctx.user.id,
          box_id: ctx.box.id,
          branch: "main"
        })

      assert {:error, %Ecto.Changeset{errors: [slug: _]}} = Repo.insert(loser)
    end
  end

  describe "housekeeping" do
    test "drops the logs of operations finished over a month ago, and nothing active", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      old = DateTime.add(DateTime.utc_now(), -40 * 86_400)

      finished =
        Operations.create!(%{
          id: Ecto.UUID.generate(),
          environment_id: env.id,
          box_id: ctx.box.id,
          action: "start",
          command: "env.start",
          status: "succeeded",
          log: "old build output",
          finished_at: old
        })

      recent =
        Operations.create!(%{
          id: Ecto.UUID.generate(),
          environment_id: env.id,
          box_id: ctx.box.id,
          action: "start",
          command: "env.start",
          status: "succeeded",
          log: "recent output",
          finished_at: DateTime.utc_now()
        })

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})

      assert Operations.get!(finished.id).log == nil
      assert Operations.get!(recent.id).log == "recent output"
    end

    test "forgets what to redact for operations that are over", ctx do
      connect_agent(ctx.box)
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, _} = Environments.stop(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      assert :ets.member(Foreman.Operations.Redactions, stop.op_id)

      Operations.get!(stop.op_id)
      |> Operations.mark("failed", finished_at: DateTime.utc_now())

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      refute :ets.member(Foreman.Operations.Redactions, stop.op_id)
    end
  end

  defp create(ctx, repo),
    do:
      Environments.create_environment(ctx.scope, %{"repo_id" => repo.id, "box_id" => ctx.box.id})

  # Answers every command the agent gets until it's quiet; returns their types.
  defp drain(box) do
    Stream.repeatedly(fn ->
      receive do
        {:dispatch, %Command{} = cmd} ->
          succeed(
            box,
            cmd,
            if(cmd.type in ["env.start", "env.restart"], do: @up_result, else: %{})
          )

          cmd.type
      after
        100 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end
end
