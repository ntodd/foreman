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
      succeed(box, cmd, %{"remote_user" => "vscode"})

      {:ok, _} = Environments.rebuild(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = rebuild}
      assert rebuild.payload.limits == %{cpus: 4, memory_mb: 6144}
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
