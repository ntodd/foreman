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
    # Nothing starts it again but a start, and nothing stops it.
    assert env.desired_state == "suspended"

    saved = %{"cpus" => 3, "memory_mb" => 4096}
    report(ctx.box, cmd, %{status: "ok", result: %{"suspended" => true, "vm_size" => saved}})
    assert %{observed_state: "suspended", vm_size: ^saved} = Repo.reload!(ctx.env)
  end

  test "a failed suspend goes back to running, with the error shown", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend"} = cmd}
    report(ctx.box, cmd, %{status: "error", error: "no room for the snapshot"})

    env = Repo.reload!(ctx.env)
    assert env.observed_state == "running"
    assert env.desired_state == "running"
    assert env.status_message == "suspend failed: no room for the snapshot"
  end

  test "resume checks the saved allocation after editing limits for the next cold boot", ctx do
    ctx.box
    |> Ecto.Changeset.change(
      capacity_policy: "refuse",
      capacity: %{"cpus" => 8, "memory_mb" => 8192},
      vm: %{
        "default_cpus" => 1,
        "default_memory_mb" => 1024,
        "host_cpus" => 8,
        "host_memory_mb" => 8192
      }
    )
    |> Repo.update!()

    env =
      ctx.env
      |> Ecto.Changeset.change(
        desired_state: "suspended",
        observed_state: "suspended",
        memory_limit_mb: 1024
      )
      |> Repo.update!()

    entry = %{
      env_id: env.id,
      slug: env.slug,
      state: "suspended",
      containers: [],
      vm_size: %{cpus: 2, memory_mb: 8192}
    }

    {:ok, event} = Event.new("box.inventory", %{environments: [entry]})
    :ok = Agents.handle_event(ctx.box.id, event)

    assert {:error, reason} = Environments.start(ctx.scope, env)
    assert reason =~ "memory"
    assert Repo.reload!(env).desired_state == "suspended"
    refute_receive {:dispatch, _}, 50
  end

  # An inventory taken while the VM was still pausing can arrive after the
  # suspend's result.
  test "a box that still says it's running is told to suspend it, not stop it", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend"} = cmd}
    report(ctx.box, cmd, %{status: "ok"})

    inventory = [%{env_id: ctx.env.id, slug: ctx.env.slug, state: "running", containers: []}]
    Environments.reconcile_inventory(ctx.box.id, inventory)
    assert_receive {:dispatch, %Command{type: "env.suspend"}}
    refute_receive {:dispatch, %Command{type: "env.stop"}}, 200
  end

  # Wanted stopped, and the box still has it saved (a stop that couldn't
  # resume it, say): stopped for good, which throws away what was saved.
  test "an environment that should be stopped but is suspended is stopped", ctx do
    {:ok, _} = Environments.stop(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.stop"} = cmd}
    report(ctx.box, cmd, %{status: "ok"})

    inventory = [%{env_id: ctx.env.id, slug: ctx.env.slug, state: "suspended", containers: []}]
    Environments.reconcile_inventory(ctx.box.id, inventory)
    assert_receive {:dispatch, %Command{type: "env.stop"}}
  end

  # A resumed environment's processes kept the secrets they had.
  test "secrets that changed while it was suspended are still pending after the resume", ctx do
    {:ok, _} = Environments.suspend(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.suspend"} = cmd}
    report(ctx.box, cmd, %{status: "ok"})

    secret_fixture("environment", ctx.env, "API_KEY", "new")
    :ok = Environments.secrets_changed([ctx.env.id])
    assert %{pending_restart: true, pending_changes: ["API_KEY"]} = Repo.reload!(ctx.env)

    {:ok, _} = Environments.start(ctx.scope, Repo.reload!(ctx.env))
    secrets_writes(ctx.box)
    assert_receive {:dispatch, %Command{type: "env.start"} = start}
    report(ctx.box, start, %{status: "ok", result: %{"resumed" => true}})

    assert %{observed_state: "running", pending_restart: true, pending_changes: ["API_KEY"]} =
             Repo.reload!(ctx.env)
  end

  # Every secrets write the box is sent, answered.
  defp secrets_writes(box) do
    receive do
      {:dispatch, %Command{type: "env.secrets.write"} = cmd} ->
        report(box, cmd, %{status: "ok"})
        secrets_writes(box)
    after
      300 -> :ok
    end
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
