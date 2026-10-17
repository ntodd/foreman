defmodule Foreman.EnvironmentsVmTest do
  @moduledoc "Environments on boxes that run each one in its own VM."
  use Foreman.DataCase

  alias Foreman.{Agents, Environments, Scope}
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id, isolation: "vm")
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, box: box, scope: Scope.for_user(user)}
  end

  defp succeed(box, cmd, result) do
    {:ok, ev} = Event.new("op.result", %{op_id: cmd.op_id, status: "ok", result: result})
    :ok = Agents.handle_event(box.id, ev)
  end

  defp create(scope, repo, box, attrs \\ %{}) do
    {:ok, env} =
      Environments.create_environment(
        scope,
        Map.merge(%{"repo_id" => repo.id, "box_id" => box.id}, attrs)
      )

    assert_receive {:dispatch, %Command{type: "env.create"} = cmd}
    {env, cmd}
  end

  describe "the size sent with create and rebuild" do
    test "is the environment's limits first", %{scope: scope, box: box} do
      repo = repo_fixture(cpu_limit: 8.0, memory_limit_mb: 16_384)

      {_env, cmd} =
        create(scope, repo, box, %{"cpu_limit" => "2", "memory_limit_mb" => "4096"})

      assert cmd.payload.limits == %{cpus: 2, memory_mb: 4096}
    end

    test "then its repo's", %{scope: scope, box: box} do
      repo =
        repo_fixture(
          cpu_limit: 3.0,
          memory_limit_mb: 6144,
          host_requirements: %{"cpus" => 8, "memory" => "16gb"}
        )

      {_env, cmd} = create(scope, repo, box)
      assert cmd.payload.limits == %{cpus: 3, memory_mb: 6144}
    end

    test "then the repo's hostRequirements", %{scope: scope, box: box} do
      repo = repo_fixture(host_requirements: %{"cpus" => 6, "memory" => "12gb"})
      {_env, cmd} = create(scope, repo, box)
      assert cmd.payload.limits == %{cpus: 6, memory_mb: 12_288}
    end

    test "then the deployment's default", %{scope: scope, box: box} do
      {_env, cmd} = create(scope, repo_fixture(), box)
      assert cmd.payload.limits == %{cpus: 4, memory_mb: 8192}

      Application.put_env(:foreman, :vm_default_cpus, 2)
      Application.put_env(:foreman, :vm_default_memory_mb, 4096)

      on_exit(fn ->
        Application.put_env(:foreman, :vm_default_cpus, 4)
        Application.put_env(:foreman, :vm_default_memory_mb, 8192)
      end)

      {_env, cmd} = create(scope, repo_fixture(), box)
      assert cmd.payload.limits == %{cpus: 2, memory_mb: 4096}
    end

    test "is worked out for CPUs and memory separately", %{scope: scope, box: box} do
      repo = repo_fixture(host_requirements: %{"memory" => "16gb"})
      {_env, cmd} = create(scope, repo, box, %{"cpu_limit" => "2"})
      assert cmd.payload.limits == %{cpus: 2, memory_mb: 16_384}
    end

    test "rounds CPUs up to whole vCPUs, the size the VM gets", %{scope: scope, box: box} do
      {_env, cmd} = create(scope, repo_fixture(), box, %{"cpu_limit" => "1.5"})
      assert cmd.payload.limits.cpus == 2
    end

    test "ignores hostRequirements no VM could have", %{scope: scope, box: box} do
      repo = repo_fixture(host_requirements: %{"cpus" => 0, "memory" => "0gb"})
      {_env, cmd} = create(scope, repo, box)
      assert cmd.payload.limits == %{cpus: 4, memory_mb: 8192}
    end

    test "goes with a rebuild too", %{scope: scope, box: box} do
      repo = repo_fixture(memory_limit_mb: 6144)
      {env, cmd} = create(scope, repo, box)
      vm = %{"name" => "fm-#{env.id}", "cpus" => 4, "memory_mb" => 6144}
      succeed(box, cmd, %{"remote_user" => "vscode", "isolation" => "vm", "vm" => vm})

      {:ok, _} = Environments.rebuild(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = rebuild}
      assert rebuild.payload.limits == %{cpus: 4, memory_mb: 6144}
    end
  end

  # A box whose isolation changed (FOREMAN_ISOLATION, or an agent rolled
  # back to protocol 2) reports the other kind's environments missing.
  # Recreating them would lose their workspace and tailnet identity.
  describe "reconcile" do
    @vm %{"name" => "fm-x", "cpus" => 4, "memory_mb" => 8192}

    test "doesn't remake a VM's environment as containers", %{user: user} do
      box = box_fixture(owner_user_id: user.id, name: "desktop")
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
      env = environment_fixture(user: user, box: box, isolation: "vm", vm: @vm)

      Environments.reconcile_inventory(box.id, [])
      refute_received {:dispatch, _}
      assert Repo.reload!(env).observed_state == "missing"

      Environments.reconcile_inventory(box.id, [])
      refute_received {:dispatch, _}
    end

    test "nor a container environment in a VM", %{user: user, box: box} do
      env = environment_fixture(user: user, box: box, isolation: "container")

      Environments.reconcile_inventory(box.id, [])
      refute_received {:dispatch, _}
      assert Repo.reload!(env).observed_state == "missing"
    end

    test "counts one that came up before isolation was recorded as containers", %{
      user: user,
      box: box
    } do
      env = environment_fixture(user: user, box: box)

      Environments.reconcile_inventory(box.id, [])
      refute_received {:dispatch, _}
      assert Repo.reload!(env).observed_state == "missing"
    end

    test "still remakes a missing environment that matches its box", %{user: user, box: box} do
      env = environment_fixture(user: user, box: box, isolation: "vm", vm: @vm)

      Environments.reconcile_inventory(box.id, [])
      assert_receive {:dispatch, %Command{type: "env.create", payload: %{env_id: id}}}
      assert id == env.id
    end

    # Nothing was marked failed, so once the box can see it again it's
    # reconciled like any other: here, started after a reboot.
    test "picks up where it was once the box changes back", %{user: user} do
      box = box_fixture(owner_user_id: user.id)
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
      env = environment_fixture(user: user, box: box, isolation: "vm", vm: @vm)

      Environments.reconcile_inventory(box.id, [])
      refute_received {:dispatch, _}

      box |> Ecto.Changeset.change(isolation: "vm") |> Repo.update!()

      Environments.reconcile_inventory(box.id, [
        %{env_id: env.id, slug: env.slug, state: "stopped"}
      ])

      assert_receive {:dispatch, %Command{type: "env.secrets.write"}}
      assert Repo.reload!(env).observed_state == "stopped"
    end

    # A box only sees its own kind, so one it reports is that kind.
    test "records the isolation of one from before it was recorded, once its box shows it", %{
      user: user,
      box: box
    } do
      env = environment_fixture(user: user, box: box)

      Environments.reconcile_inventory(box.id, [
        %{env_id: env.id, slug: env.slug, state: "running"}
      ])

      refute_received {:dispatch, _}
      assert %{isolation: "vm", observed_state: "running"} = Repo.reload!(env)
    end
  end

  # Its box can't see it, so a start or rebuild there would fail or remake
  # it from scratch, and a destroy would report success while what's on
  # the machine keeps running.
  describe "an environment made the other way from its box now" do
    test "can't be acted on until the box changes back", %{user: user, box: box, scope: scope} do
      env =
        environment_fixture(
          user: user,
          box: box,
          isolation: "container",
          observed_state: "missing"
        )

      for act <- [
            &Environments.start/2,
            &Environments.stop/2,
            &Environments.rebuild/2,
            &Environments.destroy/2,
            &Environments.git_status/2,
            &Environments.restart(&1, &2, :all)
          ] do
        assert {:error, message} = act.(scope, env)
        assert message =~ "#{env.slug} was made as containers"
        assert message =~ "#{box.name} now runs environments in VMs"
        assert message =~ "Change the box back"
      end

      refute_received {:dispatch, _}
      assert Foreman.Operations.list_for_environment(env.id, 10) == []
      assert %{desired_state: "running", destroyed_at: nil} = Repo.reload!(env)

      box |> Ecto.Changeset.change(isolation: "container") |> Repo.update!()
      assert {:ok, _} = Environments.rebuild(scope, env)
    end

    test "is still forgotten when its box is revoked", %{user: user, box: box, scope: scope} do
      env = environment_fixture(user: user, box: box, isolation: "container")
      {:ok, _} = Foreman.Boxes.revoke(Scope.for_user(user_fixture(role: "admin")), box)

      assert {:ok, _} = Environments.destroy(scope, env)
      assert Repo.reload!(env).destroyed_at
    end

    test "one that hasn't come up yet is made the box's way", %{
      user: user,
      box: box,
      scope: scope
    } do
      env =
        environment_fixture(user: user, box: box, created_once: false, observed_state: "error")

      assert {:ok, _} = Environments.retry(scope, env)
      assert_receive {:dispatch, %Command{type: "env.create"}}
    end
  end

  test "a container box still sends no limits unless some are set", %{scope: scope, user: user} do
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

    {_env, cmd} = create(scope, repo_fixture(host_requirements: %{"cpus" => 6}), box)
    assert cmd.payload.limits == %{}

    {_env, cmd} = create(scope, repo_fixture(), box, %{"cpu_limit" => "1.5"})
    assert cmd.payload.limits == %{cpus: 1.5}
  end
end
