defmodule Foreman.WorkloadDispatchTest do
  use Foreman.DataCase

  alias Foreman.{Accounts, Environments, Operations, Scope}
  alias Foreman.Environments.Server
  alias ForemanProtocol.Command

  setup do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, box: box)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, env: env, admin: user_fixture(role: "admin")}
  end

  test "a queued command loses authority when its actor is disabled", ctx do
    op = queued(ctx.env, ctx.user, "connect")
    {:ok, _} = Accounts.set_disabled(Scope.for_user(ctx.admin), ctx.user, true)
    Server.kick(ctx.env.id)
    refute_receive {:dispatch, _}
    assert Operations.get!(op.id).status == "failed"
    assert Repo.reload!(ctx.env).observed_state == "running"
  end

  test "a reconnect never rewrites files or resends a disabled actor's start", ctx do
    op = queued(ctx.env, ctx.user, "start") |> Operations.mark("dispatched")
    :ok = Accounts.revoke_access(ctx.user, "org membership ended")
    Server.resend(ctx.env.id, op.id)
    refute_receive {:dispatch, _}
    assert Operations.get!(op.id).status == "failed"
  end

  test "disabled owners receive no reconciled work or secret refresh, admins can still stop",
       ctx do
    {:ok, _} = Accounts.set_disabled(Scope.for_user(ctx.admin), ctx.user, true)
    Environments.push_secrets(user_id: ctx.user.id)
    Environments.reconcile_inventory(ctx.env.box_id, [])
    refute_receive {:dispatch, _}
    refute Operations.active?(ctx.env.id)
    assert {:ok, _} = Environments.stop(Scope.for_user(ctx.admin), Repo.reload!(ctx.env))
    assert_receive {:dispatch, %Command{type: "env.stop"}}
  end

  defp queued(env, user, action) do
    Operations.create!(%{
      environment_id: env.id,
      box_id: env.box_id,
      user_id: user.id,
      action: action,
      command: "env." <> action,
      args: %{"hook" => "code", "action" => "open"}
    })
  end
end
