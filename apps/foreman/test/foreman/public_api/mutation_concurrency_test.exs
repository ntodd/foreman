defmodule Foreman.PublicAPI.MutationConcurrencyTest do
  # These calls must commit, so each participant checks out its own ordinary
  # connection. A shared SQL Sandbox transaction cannot exercise this race.
  use ExUnit.Case, async: false
  import Ecto.Query
  import Foreman.Fixtures
  import Foreman.PublicAPIMutationFixtures
  alias Ecto.Adapters.SQL.Sandbox

  alias Foreman.{
    Agents,
    Environments,
    Environments.Environment,
    Jobs.EnvironmentExpiry,
    Operations,
    Operations.Operation,
    PublicAPI.Mutations,
    PublicAPI.Receipt,
    Repo
  }

  setup :local_git

  setup do
    Sandbox.unboxed_run(Repo, fn ->
      user = user_fixture()
      box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
      repo = repo_fixture() |> Ecto.Changeset.change(private: false) |> Repo.update!()
      {actor, _grant} = principal(user)
      Registry.register(Foreman.Registry, {:agent, box.id}, nil)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          ids = from(e in Environment, where: e.user_id == ^user.id, select: e.id)
          Repo.delete_all(from r in Receipt, where: r.environment_id in subquery(ids))
          Repo.delete_all(from a in Foreman.Audit.Event, where: a.actor_id == ^user.id)
          Repo.delete_all(from e in Environment, where: e.user_id == ^user.id)
          Repo.delete!(Repo.reload!(box))
          Repo.delete!(repo.owner)
          Repo.delete!(user)
        end)
      end)

      %{actor: actor, repo: repo, box: box}
    end)
  end

  test "concurrent agent acceptance cannot reopen a timeout or reset its retention deadline",
       ctx do
    parent = self()
    handler = make_ref()

    # Stop after the acceptance's first statement on the operation. A separate
    # read followed by an unconditional write would overwrite the committed timeout.
    :ok =
      :telemetry.attach(
        handler,
        [:foreman, :repo, :query],
        fn _, _, meta, owner ->
          if meta.source == "operations" and Process.delete(:pause_acceptance) do
            send(owner, {:accepting, self()})

            receive do
              :continue -> :ok
            after
              5_000 -> raise "timeout writer did not release the accepting connection"
            end
          end
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Sandbox.unboxed_run(Repo, fn ->
      env = environment_fixture(user: ctx.actor.user, box: ctx.box, repo: ctx.repo)

      op =
        Operations.create!(%{
          environment_id: env.id,
          box_id: ctx.box.id,
          action: "start",
          command: "env.start",
          status: "dispatched",
          dispatched_at: DateTime.utc_now()
        })

      acceptance =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Process.put(:pause_acceptance, true)
            Operations.mark_running(op.id)
          end)
        end)

      assert_receive {:accepting, pid}, 5_000
      assert {:ok, failed} = Operations.timed_out(op, "timeout")
      send(pid, :continue)
      Task.await(acceptance)

      refute Operations.active?(env.id)
      assert :finished = Operations.timed_out(op, "second timeout")
      assert {:ok, reconciled} = Operations.finish(op.id, "ok", %{}, nil)
      assert reconciled.finished_at == failed.finished_at
      assert reconciled.timeout_error == failed.timeout_error
    end)
  end

  test "independent transactions cannot see an uncommitted reservation or dispatch and identical retries recover it",
       ctx do
    parent = self()
    handler = make_ref()

    # Pause the winner after recording BOTH result IDs, before COMMIT.
    :ok =
      :telemetry.attach(
        handler,
        [:foreman, :repo, :query],
        fn _, _, meta, owner ->
          if Process.get(:hold_receipt, false) and String.starts_with?(meta.query, "UPDATE") and
               meta.source == "api_mutation_receipts" do
            send(owner, {:recorded, self()})

            receive do
              :commit -> :ok
            after
              5_000 -> raise "coordinator did not release writer"
            end
          end
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    input = %{"repo_id" => ctx.repo.id}

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(:hold_receipt, true)
          Mutations.create(ctx.actor, "same", input)
        end)
      end)

    assert_receive {:recorded, writer_pid}, 5_000

    contender =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          assert Repo.aggregate(
                   from(e in Environment, where: e.user_id == ^ctx.actor.user.id),
                   :count
                 ) == 0

          send(parent, :submitting_retry)
          Mutations.create(ctx.actor, "same", input)
        end)
      end)

    assert_receive :submitting_retry, 5_000
    refute_receive {:dispatch, _}, 100
    assert Task.yield(contender, 50) == nil
    send(writer_pid, :commit)
    assert {:ok, env, op} = Task.await(writer)
    assert {:ok, ^env, ^op} = Task.await(contender)
    assert_receive {:dispatch, %{op_id: ^op}}
    refute_receive {:dispatch, _}

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(e in Environment, where: e.user_id == ^ctx.actor.user.id),
               :count
             ) == 1

      assert Repo.aggregate(from(o in Operation, where: o.environment_id == ^env), :count) == 1
      assert Repo.aggregate(from(r in Receipt, where: r.environment_id == ^env), :count) == 1
    end)
  end

  test "a concurrent create replay survives its repo leaving the launch catalog", ctx do
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:foreman, :repo, :query],
        fn _, _, meta, parent ->
          if meta.source == "api_mutation_receipts" and String.starts_with?(meta.query, "SELECT") and
               Process.delete(:pause_after_receipt_read) do
            send(parent, {:receipt_read, self()})

            receive do
              :continue -> :ok
            after
              5000 -> raise "concurrent create did not finish"
            end
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    input = %{"repo_id" => ctx.repo.id}

    retry =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(:pause_after_receipt_read, true)
          Mutations.create(ctx.actor, "same", input)
        end)
      end)

    assert_receive {:receipt_read, pid}, 5000

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, env, op} = Mutations.create(ctx.actor, "same", input)
      Repo.update!(Ecto.Changeset.change(ctx.repo, archived: true))
      send(pid, :continue)
      assert {:ok, ^env, ^op} = Task.await(retry)
      assert {:error, :resource_not_found, _} = Mutations.create(ctx.actor, "new-key", input)
      refute Repo.get(Receipt, Receipt.key_hash(ctx.actor, "environments", "new-key"))

      Repo.update!(Ecto.Changeset.change(ctx.repo, private: true))
      assert {:error, :resource_not_found, _} = Mutations.create(ctx.actor, "same", input)
    end)
  end

  test "an outer rollback sends no agent command and leaves the key available", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      input = %{"repo_id" => ctx.repo.id}

      assert {:error, :abort} =
               Repo.transact(fn ->
                 assert {:ok, _, _} = Mutations.create(ctx.actor, "retry", input)
                 refute_received {:dispatch, _}
                 {:error, :abort}
               end)

      assert Repo.aggregate(
               from(e in Environment, where: e.user_id == ^ctx.actor.user.id),
               :count
             ) == 0

      assert {:ok, _env, op} = Mutations.create(ctx.actor, "retry", input)
      assert_receive {:dispatch, %{op_id: ^op}}
    end)
  end

  test "two distinct requests contend for the final capacity slot", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.update!(
        Ecto.Changeset.change(ctx.box,
          capacity_policy: "refuse",
          capacity: %{"cpus" => 2},
          cpu_threshold: 1.0
        )
      )

      Repo.update!(Ecto.Changeset.change(ctx.repo, cpu_limit: 2.0))
    end)

    input = %{"repo_id" => ctx.repo.id, "box_id" => ctx.box.id}
    outcomes = together(fn key -> Mutations.create(ctx.actor, key, input) end)
    assert Enum.count(outcomes, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, :capacity_exceeded, _}, &1)) == 1
  end

  test "simultaneous distinct lifecycle keys coalesce on a single stop operation", ctx do
    env =
      Sandbox.unboxed_run(Repo, fn ->
        environment_fixture(user: ctx.actor.user, box: ctx.box, repo: ctx.repo)
      end)

    [one, two] =
      together(fn key -> Mutations.operate(ctx.actor, env.id, key, %{"action" => "stop"}) end)

    assert {:ok, _, op} = one
    assert is_binary(op)
    assert one == two

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(o in Operation, where: o.environment_id == ^env.id), :count) == 1
    end)
  end

  for action <- ~w(stop destroy), delivery <- [:online, :offline] do
    @action action
    @delivery delivery
    test "fulfilled #{action} survives #{delivery} delivery of a claimed retry", ctx do
      # Stop just after the durable claim, before the channel receives the command.
      handler = make_ref()

      :ok =
        :telemetry.attach(
          handler,
          [:foreman, :repo, :query],
          fn _, _, meta, pid ->
            if meta.source == "operations" and String.starts_with?(meta.query, "UPDATE") and
                 String.contains?(meta.query, "dispatched_at") and
                 Process.delete(:pause_retry_claim) do
              send(pid, {:claimed, self()})

              receive do
                :deliver -> :ok
              after
                5000 -> raise "retry was not released"
              end
            end
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      Sandbox.unboxed_run(Repo, fn ->
        env = environment_fixture(user: ctx.actor.user, box: ctx.box, repo: ctx.repo)

        Repo.update!(
          Ecto.Changeset.change(env,
            expiry_at: DateTime.add(DateTime.utc_now(), -1),
            expiry_action: @action
          )
        )

        job = %{args: %{"environment_id" => env.id}}

        on_exit(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.delete_all(
              from j in Oban.Job,
                where: j.args["environment_id"] == ^env.id or j.args["slug"] == ^env.slug
            )

            Repo.delete_all(from a in Foreman.Audit.Event, where: a.subject_id == ^env.id)
          end)
        end)

        :ok = EnvironmentExpiry.perform(job)
        assert_receive {:dispatch, %{op_id: first}}

        assert {:ok, timeout, _} =
                 Operations.timed_out(
                   Operations.get!(first),
                   "timeout",
                   &Environments.record_result/1
                 )

        task =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Process.put(:pause_retry_claim, true)
              EnvironmentExpiry.perform(job)
            end)
          end)

        assert_receive {:claimed, dispatcher}, 5000

        finish = fn id ->
          {:ok, success} = ForemanProtocol.Event.new("op.result", %{op_id: id, status: "ok"})
          Agents.handle_event(env.box_id, success)
        end

        assert :ok = finish.(first)
        settled = Repo.reload!(env)
        assert settled.expiry_consumed_at
        assert settled.observed_state == if(@action == "stop", do: "stopped", else: "destroyed")
        if @delivery == :offline, do: Registry.unregister(Foreman.Registry, {:agent, env.box_id})
        send(dispatcher, :deliver)
        assert :ok = Task.await(task)

        retry =
          Repo.one!(from o in Operation, where: o.environment_id == ^env.id and o.id != ^first)

        check_expiry_delivery(@delivery, retry, finish)
        assert Repo.reload!(env) == settled
        assert Operations.get!(first).finished_at == timeout.finished_at

        {reader, _} = principal(ctx.actor.user, ~w(environments:read operations:list))
        conn = Phoenix.ConnTest.build_conn() |> Plug.Conn.assign(:api_principal, reader)
        params = %{"id" => env.id}
        history = ForemanWeb.PublicReadController.operations(conn, params)
        retry_status = if @delivery == :online, do: "succeeded", else: "cancelled"
        retry_id = retry.id

        assert [
                 %{"id" => ^retry_id, "trigger" => "expiry", "status" => ^retry_status},
                 %{
                   "id" => ^first,
                   "trigger" => "expiry",
                   "status" => "failed",
                   "error" => %{"code" => "operation_timeout", "message" => "timeout"}
                 }
               ] = Phoenix.ConnTest.json_response(history, 200)["items"]

        response = ForemanWeb.PublicReadController.environment(conn, params)

        if @action == "stop" do
          assert Phoenix.ConnTest.json_response(response, 200)["observed_state"] == "stopped"
        else
          assert Phoenix.ConnTest.json_response(response, 404)["code"] == "resource_not_found"
        end
      end)
    end
  end

  defp check_expiry_delivery(:online, retry, finish) do
    assert_receive {:dispatch, %{op_id: id}}
    assert id == retry.id
    assert :ok = finish.(id)
    assert Repo.reload!(retry).status == "succeeded"
  end

  defp check_expiry_delivery(:offline, retry, _finish) do
    refute_received {:dispatch, _}
    assert retry.status == "cancelled"
  end

  defp together(fun) do
    parent = self()

    tasks =
      for key <- ~w(one two) do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:checked_out, self()})

            receive do
              :submit -> fun.(key)
            end
          end)
        end)
      end

    for _ <- tasks, do: assert_receive({:checked_out, _}, 5_000)
    for task <- tasks, do: send(task.pid, :submit)
    Task.await_many(tasks)
  end
end
