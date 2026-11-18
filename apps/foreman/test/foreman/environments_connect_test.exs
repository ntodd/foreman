defmodule Foreman.EnvironmentsConnectTest do
  @moduledoc """
  Connect hooks: the actions a feature puts on an environment's page (see
  `ForemanProtocol.Connect`). Their results are secrets, shown once to the
  person who asked and never stored.
  """
  use Foreman.DataCase

  alias Foreman.{Agents, Audit, Environments, Operations, Scope}
  alias ForemanProtocol.{Command, Event}

  @orca %{
    "name" => "orca",
    "label" => "Orca",
    "actions" => [
      %{"id" => "desktop", "label" => "Pair a desktop", "confirm" => "Orca restarts."},
      %{"id" => "mobile", "label" => "Pair a phone", "confirm" => nil}
    ]
  }

  @offer %{"value" => "orca://pair?code=s3cretc0de", "qr" => false, "note" => "Paste it."}

  setup do
    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, repo: repo, box: box, scope: Scope.for_user(user)}
  end

  defp result(box, cmd, status \\ "ok", result) do
    {:ok, ev} = Event.new("op.result", %{op_id: cmd.op_id, status: status, result: result})
    :ok = Agents.handle_event(box.id, ev)
  end

  defp env_with_hooks(ctx, attrs \\ []) do
    env =
      environment_fixture(Keyword.merge([user: ctx.user, repo: ctx.repo, box: ctx.box], attrs))

    env |> Ecto.Changeset.change(connect_hooks: [@orca]) |> Repo.update!()
  end

  describe "hooks from results" do
    test "an up records the hooks it found, dropping any that don't fit", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)

      {:ok, _} = Environments.rebuild(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = rebuild}
      result(ctx.box, rebuild, %{"remote_user" => "vscode", "connect" => [@orca, %{"x" => 1}]})

      assert Repo.reload!(env).connect_hooks == [@orca]
    end

    test "an up that found none clears them", ctx do
      env = env_with_hooks(ctx)

      {:ok, _} = Environments.rebuild(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = rebuild}
      result(ctx.box, rebuild, %{"remote_user" => "vscode", "connect" => []})

      assert Repo.reload!(env).connect_hooks == []
    end

    # Every up from an agent that can run hooks reports them, so this is an
    # older one (a box rolled back), which can't.
    test "an up that doesn't say clears them", ctx do
      env = env_with_hooks(ctx)

      {:ok, _} = Environments.rebuild(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = rebuild}
      result(ctx.box, rebuild, %{"remote_user" => "vscode"})

      assert Repo.reload!(env).connect_hooks == []
    end

    test "restarting everything records them too", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)

      {:ok, _} = Environments.restart(ctx.scope, env, :all)
      assert_receive {:dispatch, %Command{type: "env.restart"} = restart}
      result(ctx.box, restart, %{"restarted" => "all", "connect" => [@orca]})

      assert Repo.reload!(env).connect_hooks == [@orca]
    end
  end

  describe "connect/4" do
    test "sends the hook's action to the agent, and audits it without a result", ctx do
      env = env_with_hooks(ctx)

      assert {:ok, op} = Environments.connect(ctx.scope, env, "orca", "desktop")
      assert op.action == "connect"
      assert_receive {:dispatch, %Command{type: "env.connect", payload: payload}}
      assert %{hook: "orca", action: "desktop", slug: _} = payload

      assert [%{metadata: metadata}] =
               Enum.filter(Audit.recent(), &(&1.action == "environment.connect"))

      assert metadata == %{"hook" => "orca", "action" => "desktop"}
    end

    test "is for the environment's owner only, not an admin", ctx do
      env = env_with_hooks(ctx)
      admin = Scope.for_user(user_fixture(role: "admin"))

      assert {:error, :unauthorized} = Environments.connect(admin, env, "orca", "desktop")
      refute_receive {:dispatch, _}
    end

    test "takes only an action the environment reported", ctx do
      env = env_with_hooks(ctx)

      assert {:error, _} = Environments.connect(ctx.scope, env, "orca", "tablet")
      assert {:error, _} = Environments.connect(ctx.scope, env, "other", "desktop")
      refute_receive {:dispatch, _}
    end

    test "needs it running on a box that's online", ctx do
      stopped = env_with_hooks(ctx, observed_state: "stopped")
      assert {:error, message} = Environments.connect(ctx.scope, stopped, "orca", "desktop")
      assert message =~ "running"

      Registry.unregister(Foreman.Registry, {:agent, ctx.box.id})
      env = env_with_hooks(ctx)
      assert {:error, message} = Environments.connect(ctx.scope, env, "orca", "desktop")
      assert message =~ "offline"
    end

    test "two requests are two operations, each with its own action", ctx do
      env = env_with_hooks(ctx)

      {:ok, first} = Environments.connect(ctx.scope, env, "orca", "desktop")
      {:ok, second} = Environments.connect(ctx.scope, env, "orca", "mobile")

      assert first.id != second.id
      assert second.args == %{"hook" => "orca", "action" => "mobile"}
    end
  end

  describe "the offer" do
    setup ctx do
      env = env_with_hooks(ctx)
      # The caller is subscribed before the operation can go out.
      {:ok, op} = Environments.connect(ctx.scope, env, "orca", "desktop")
      assert_receive {:dispatch, %Command{type: "env.connect"} = cmd}
      %{env: env, op: op, cmd: cmd}
    end

    test "goes to whoever subscribed, and isn't stored", ctx do
      Operations.subscribe(ctx.op.id)
      result(ctx.box, ctx.cmd, %{"offer" => @offer})

      assert_receive {:connect_offer, op_id, offer}
      assert op_id == ctx.op.id
      assert offer == @offer

      op = Operations.get!(ctx.op.id)
      assert op.status == "succeeded"
      refute inspect(op) =~ "s3cretc0de"
      assert_receive {:operation, %{status: "succeeded"} = broadcast}
      refute inspect(broadcast) =~ "s3cretc0de"
    end

    test "one that doesn't fit fails the operation", ctx do
      result(ctx.box, ctx.cmd, %{"offer" => %{"value" => "a\nb"}})

      refute_receive {:connect_offer, _, _}
      op = Operations.get!(ctx.op.id)
      assert op.status == "failed"
      assert op.error =~ "result"
      refute inspect(op) =~ "a\nb"
    end

    test "a failed action says why", ctx do
      {:ok, ev} =
        Event.new("op.result", %{
          op_id: ctx.cmd.op_id,
          status: "error",
          error: "connect hook orca failed: no pairing offer"
        })

      :ok = Agents.handle_event(ctx.box.id, ev)

      refute_receive {:connect_offer, _, _}
      assert Operations.get!(ctx.op.id).error =~ "no pairing offer"
    end

    test "a connect that never comes back is given up on after minutes, not hours", ctx do
      ten_minutes_ago = DateTime.add(DateTime.utc_now(), -11 * 60)

      Repo.update!(
        Ecto.Changeset.change(ctx.op |> Repo.reload!(), dispatched_at: ten_minutes_ago)
      )

      Foreman.Jobs.Housekeeping.perform(%Oban.Job{})

      op = Operations.get!(ctx.op.id)
      assert op.status == "failed"
      assert op.error =~ "minutes"
    end

    test "doesn't leave the environment looking broken when it fails", ctx do
      result(ctx.box, ctx.cmd, "error", %{})
      env = Repo.reload!(ctx.env)
      assert env.observed_state == "running"
      assert env.status_message == nil
    end
  end
end
