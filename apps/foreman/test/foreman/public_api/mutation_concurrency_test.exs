defmodule Foreman.PublicAPI.MutationConcurrencyTest do
  # These calls must commit, so each participant checks out its own ordinary
  # connection. A shared SQL Sandbox transaction cannot exercise this race.
  use ExUnit.Case, async: false
  import Ecto.Query
  import Foreman.Fixtures
  import Foreman.PublicAPIMutationFixtures
  alias Ecto.Adapters.SQL.Sandbox

  alias Foreman.{
    Environments.Environment,
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
