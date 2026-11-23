defmodule Foreman.PublicAPI.RestartTest do
  @moduledoc "Restarting a running environment's services through the public API."
  use Foreman.DataCase

  import Foreman.PublicAPIMutationFixtures
  setup :local_git

  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation
  alias Foreman.PublicAPI.Mutations

  # A workspace the box has confirmed is running, as a restart requires.
  setup do
    user = user_fixture()
    repo = repo_fixture() |> change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    {actor, _} = principal(user)

    assert {:ok, id, create} = Mutations.create(actor, "create", %{"repo_id" => repo.id})
    complete(box, create)
    flush()

    %{actor: actor, user: user, repo: repo, box: box, env: Repo.get!(Environment, id)}
  end

  defp complete(box, op_id) do
    {:ok, result} =
      ForemanProtocol.Event.new("op.result", %{op_id: op_id, status: "ok", result: %{}})

    assert :ok = Foreman.Agents.handle_event(box.id, result)
  end

  # Acknowledge whatever the box is sent until `op` itself has finished.
  defp complete_all(box, op) do
    receive do
      {:dispatch, %ForemanProtocol.Command{op_id: id}} ->
        complete(box, id)
        if id != op, do: complete_all(box, op)
    after
      500 -> flunk("the box was never sent #{op}")
    end
  end

  # Acknowledge everything the box has been sent, until it is sent nothing more.
  defp settle(box) do
    receive do
      {:dispatch, %ForemanProtocol.Command{op_id: id}} ->
        complete(box, id)
        settle(box)
    after
      50 -> :ok
    end
  end

  defp flush do
    receive do
      {:dispatch, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp pending(env, names),
    do: env |> change(pending_restart: names != [], pending_changes: names) |> Repo.update!()

  defp restart(actor, env, action, key \\ nil),
    do: Mutations.operate(actor, env.id, key || action, %{"action" => action})

  test "restart_all queues a restart of every service, attributed to the connection", ctx do
    env_id = ctx.env.id
    grant = ctx.actor.grant_id

    assert {:ok, ^env_id, op_id} = restart(ctx.actor, ctx.env, "restart_all")

    assert %Operation{action: "restart_all", api_grant_id: ^grant} = Repo.get!(Operation, op_id)

    assert Repo.reload!(ctx.env).desired_state == "running"

    assert %{metadata: %{"client_id" => "foreman-cli"}} =
             Enum.find(Foreman.Audit.recent(), &(&1.action == "environment.restart_all"))

    # The same key replays the same operation; a new key follows the one in flight.
    assert {:ok, ^env_id, ^op_id} = restart(ctx.actor, ctx.env, "restart_all")
    assert {:ok, ^env_id, ^op_id} = restart(ctx.actor, ctx.env, "restart_all", "second key")
    assert Repo.aggregate(from(o in Operation, where: o.action == "restart_all"), :count) == 1
  end

  test "restart_affected always restarts, and carries the names known to have changed", ctx do
    env_id = ctx.env.id

    # Queued even with nothing pending: whether a restart happens must not
    # say whether a secret just sent matched the one already applied.
    assert {:ok, ^env_id, quiet} =
             restart(ctx.actor, ctx.env, "restart_affected", "nothing pending")

    assert %Operation{action: "restart_affected", args: %{"changed" => []}} =
             Repo.get!(Operation, quiet)

    complete_all(ctx.box, quiet)

    pending(Repo.reload!(ctx.env), ["API_KEY", "DATABASE_URL"])
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
    assert {:ok, _, stop} =
             Mutations.operate(ctx.actor, ctx.env.id, "stop", %{"action" => "stop"})

    complete(ctx.box, stop)
    env_id = ctx.env.id

    assert {:ok, ^env_id, start} =
             Mutations.operate(ctx.actor, env_id, "start", %{"action" => "start"})

    assert is_binary(start)
    assert {:error, :lifecycle_conflict, _} = restart(ctx.actor, ctx.env, "restart_all")

    assert {:ok, ^env_id, ^start} =
             Mutations.operate(ctx.actor, env_id, "again", %{"action" => "start"})
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

  test "an environment whose VM is not confirmed running conflicts, pending or not", ctx do
    for observed <- ~w(stopped error) do
      env = ctx.env |> change(observed_state: observed) |> Repo.update!() |> pending([])

      assert {:error, :lifecycle_conflict, _} =
               restart(ctx.actor, env, "restart_affected", observed)

      pending(env, ["A"])

      assert {:error, :lifecycle_conflict, _} =
               restart(ctx.actor, env, "restart_affected", observed <> " pending")

      assert {:error, :lifecycle_conflict, _} =
               restart(ctx.actor, env, "restart_all", observed <> " all")
    end

    refute Repo.exists?(from o in Operation, where: o.action in ~w(restart_all restart_affected))
  end

  describe "at dispatch" do
    alias ForemanProtocol.Command

    # The current files go to the box first, then the restart.
    defp files_then_restart(box, op) do
      assert_receive {:dispatch, %Command{type: "env.secrets.write", op_id: files}}
      refute_received {:dispatch, %Command{type: "env.restart"}}
      complete(box, files)
      assert_receive {:dispatch, %Command{type: "env.restart", op_id: ^op}}
      assert Repo.get!(Operation, op).status == "dispatched"
    end

    test "an accepted restart is sent to the box after the current files, for both kinds", ctx do
      assert {:ok, _, all} = restart(ctx.actor, ctx.env, "restart_all")
      files_then_restart(ctx.box, all)
      complete(ctx.box, all)

      pending(Repo.reload!(ctx.env), ["A"])
      assert {:ok, _, affected} = restart(ctx.actor, ctx.env, "restart_affected")
      files_then_restart(ctx.box, affected)
    end

    test "the owner's new connection can restart a workspace an earlier one launched", ctx do
      {newer, _} = principal(ctx.user)
      assert ctx.env.api_grant_id == ctx.actor.grant_id

      # The workspace is running on the authority of a start through the
      # connection that launched it, and that connection is then replaced.
      launched = %{
        "action" => "start",
        "user_id" => ctx.user.id,
        "grant_id" => ctx.actor.grant_id,
        "trigger" => "request"
      }

      ctx.env |> change(desired_authority: launched) |> Repo.update!()
      Foreman.OAuth.revoke_grant(ctx.actor.grant_id)
      owner = Foreman.Scope.for_user(ctx.user)

      # A changed secret can no longer be written to the box on that authority.
      {:ok, _} = Foreman.Secrets.apply_changes(owner, "environment", ctx.env, [{"A", "1"}], [])
      refute_receive {:dispatch, %Command{type: "env.secrets.write"}}

      # The restart delivers it on the new connection's, before anything restarts,
      # and the workspace runs on the new connection's authority from then on.
      assert {:ok, _, op} = restart(newer, ctx.env, "restart_all")
      files_then_restart(ctx.box, op)
      env = Repo.reload!(ctx.env)
      assert env.workload_grant_id == newer.grant_id
      assert %{"grant_id" => grant, "action" => "restart_all"} = env.desired_authority
      assert grant == newer.grant_id
      complete(ctx.box, op)

      # So the next change reaches the box without another restart.
      settle(ctx.box)

      {:ok, _} =
        Foreman.Secrets.apply_changes(owner, "environment", ctx.env, [{"A", "second-value"}], [])

      assert_receive {:dispatch, %Command{type: "env.secrets.write", payload: payload}}
      assert inspect(payload) =~ "second-value"
    end

    test "a restart sent again after a stop was asked for leaves the stop in charge", ctx do
      assert {:ok, _, op} = restart(ctx.actor, ctx.env, "restart_all")
      files_then_restart(ctx.box, op)

      # The owner stops it in the browser while the restart is still out.
      {:ok, _} =
        Foreman.Environments.stop(Foreman.Scope.for_user(ctx.user), Repo.reload!(ctx.env))

      stopping = Repo.reload!(ctx.env)
      assert stopping.desired_state == "stopped"

      Foreman.Environments.Server.resend(ctx.env.id, op)

      after_resend = Repo.reload!(ctx.env)
      assert after_resend.desired_state == "stopped"
      assert after_resend.desired_authority == stopping.desired_authority
    end

    test "a restart sent again after a newer request for running leaves that one in charge",
         ctx do
      assert {:ok, _, op} = restart(ctx.actor, ctx.env, "restart_all")
      files_then_restart(ctx.box, op)

      # An admin rebuilds it in the browser while the restart is still out.
      admin = user_fixture(role: "admin")

      {:ok, _} =
        Foreman.Environments.rebuild(Foreman.Scope.for_user(admin), Repo.reload!(ctx.env))

      rebuilding = Repo.reload!(ctx.env)
      assert %{"action" => "rebuild", "user_id" => admin_id} = rebuilding.desired_authority
      assert admin_id == admin.id

      Foreman.Environments.Server.resend(ctx.env.id, op)
      assert Repo.reload!(ctx.env).desired_authority == rebuilding.desired_authority
    end

    test "a restart refused at dispatch leaves the authority behind the workspace alone", ctx do
      earlier = %{
        "action" => "start",
        "user_id" => ctx.user.id,
        "grant_id" => ctx.actor.grant_id,
        "trigger" => "request"
      }

      ctx.env |> change(desired_authority: earlier) |> Repo.update!()
      {other, _} = principal(ctx.user)

      # Queued without the kick the API gives it, so the grant can go first.
      {:ok, op} =
        Foreman.Environments.queue_action(
          Foreman.Scope.for_user(ctx.user),
          Repo.reload!(ctx.env),
          :restart_all,
          %{},
          api_grant_id: other.grant_id,
          audit: %{},
          dedupe: false
        )

      assert Repo.reload!(ctx.env).desired_authority == earlier
      refute Map.has_key?(Repo.get!(Operation, op.id).args, "prior_authority")

      Foreman.OAuth.revoke_grant(other.grant_id)
      Foreman.Environments.Server.kick(ctx.env.id)

      refute_receive {:dispatch, %Command{type: "env.restart"}}
      assert Repo.get!(Operation, op.id).status == "failed"
      env = Repo.reload!(ctx.env)
      assert env.desired_state == "running"
      assert env.desired_authority == earlier
    end
  end
end
