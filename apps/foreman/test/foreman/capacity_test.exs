defmodule Foreman.CapacityTest do
  use Foreman.DataCase

  alias Foreman.Boxes.Box
  alias Foreman.Capacity
  alias Foreman.Capacity.Tracker
  alias Foreman.Environments.Environment

  describe "provisioned/2" do
    test "limits first, then hostRequirements, then the observed average" do
      repo = repo_fixture(host_requirements: %{"cpus" => 4, "memory" => "8gb"})

      assert %{cpus: 2, memory_mb: 8192, source: :limits} =
               Capacity.provisioned(%Environment{id: "a", cpu_limit: 2}, repo)

      assert %{cpus: 4, memory_mb: 8192, source: :host_requirements} =
               Capacity.provisioned(%Environment{id: "b"}, repo)

      bare = repo_fixture()
      env_id = Ecto.UUID.generate()
      now = System.system_time(:second)

      Tracker.record(
        "box",
        %{capacity: %{}, environments: %{env_id => %{cpu_percent: 150.0, memory_mb: 1024}}},
        now - 60
      )

      Tracker.record(
        "box",
        %{capacity: %{}, environments: %{env_id => %{cpu_percent: 50.0, memory_mb: 3072}}},
        now
      )

      assert %{cpus: 1.0, memory_mb: 2048.0, source: :observed} =
               Capacity.provisioned(%Environment{id: env_id}, bare)

      assert %{source: :unknown} =
               Capacity.provisioned(%Environment{id: Ecto.UUID.generate()}, bare)
    end

    test "parses hostRequirements memory sizes" do
      assert Capacity.parse_size("8gb") == 8192
      assert Capacity.parse_size("512mb") == 512
      assert Capacity.parse_size("1.5GB") == 1536
      assert Capacity.parse_size("1tb") == 1_048_576
      assert Capacity.parse_size("lots") == nil
    end
  end

  defp vm_box(capacity),
    do: %Box{id: Ecto.UUID.generate(), name: "vms", isolation: "vm", capacity: capacity}

  describe "on a VM box" do
    # A VM holds its whole size while it runs, however little it uses.
    test "an environment counts its VM's size ahead of everything else" do
      repo = repo_fixture(host_requirements: %{"cpus" => 8, "memory" => "16gb"})

      env = %Environment{
        id: Ecto.UUID.generate(),
        cpu_limit: 2.0,
        vm: %{"name" => "fm-x", "cpus" => 4, "memory_mb" => 6144}
      }

      assert %{cpus: 4, memory_mb: 6144, source: :vm} = Capacity.provisioned(env, repo)
    end

    test "before its VM is made, it counts the size the VM will get" do
      box = %Box{isolation: "vm"}
      env_id = Ecto.UUID.generate()

      Tracker.record(
        "box",
        %{capacity: %{}, environments: %{env_id => %{cpu_percent: 10.0, memory_mb: 512}}},
        System.system_time(:second)
      )

      repo = repo_fixture(host_requirements: %{"cpus" => 6, "memory" => "12gb"})

      assert %{cpus: 6, memory_mb: 12_288, source: :vm} =
               Capacity.provisioned(%Environment{id: env_id, box: box}, repo)

      assert %{cpus: 4, memory_mb: 8192, source: :vm} =
               Capacity.provisioned(%Environment{id: env_id, box: box}, repo_fixture())
    end

    test "the box adds up its running VMs" do
      box = vm_box(%{"cpus" => 16, "memory_mb" => 65_536})
      repo = repo_fixture()

      envs =
        for state <- ["running", "running", "stopped"],
            do: %Environment{id: Ecto.UUID.generate(), observed_state: state, repo: repo}

      summary = Capacity.box_summary(box, envs)
      assert summary.provisioned_cpus == 8
      assert summary.provisioned_memory_mb == 16_384
    end

    test "placement counts the new environment's VM too" do
      box = vm_box(%{"cpus" => 16, "memory_mb" => 16_384})
      repo = repo_fixture()

      running = [
        %Environment{
          id: Ecto.UUID.generate(),
          observed_state: "running",
          repo: repo,
          vm: %{"name" => "fm-a", "cpus" => 4, "memory_mb" => 8192}
        }
      ]

      assert {:contention, message} = Capacity.check_placement(box, running, repo)
      assert message =~ "past 90%"

      # The same environments in containers, with nothing measured yet, fit.
      container_box = %{box | isolation: "container"}
      bare = Enum.map(running, &%{&1 | vm: nil})
      assert :ok = Capacity.check_placement(container_box, bare, repo)
    end
  end

  # A box that changed isolation can't see the other kind's environments,
  # and they're out of its stats, but what was running is most likely
  # still running: VMs outlive the agent, and so do containers.
  describe "after a box changes isolation" do
    test "what it can't see still counts while it should be running" do
      repo = repo_fixture()
      vm = %{"name" => "fm-a", "cpus" => 4, "memory_mb" => 8192}

      made_as =
        fn isolation, attrs ->
          struct!(
            %Environment{
              id: Ecto.UUID.generate(),
              repo: repo,
              created_once: true,
              observed_state: "missing",
              isolation: isolation
            },
            attrs
          )
        end

      container_box = %{vm_box(%{"cpus" => 16, "memory_mb" => 65_536}) | isolation: "container"}

      # One wanted gone whose destroy couldn't be sent is still there too.
      summary =
        Capacity.box_summary(container_box, [
          made_as.("vm", vm: vm),
          made_as.("vm", vm: vm, desired_state: "destroyed"),
          made_as.("vm", vm: vm, desired_state: "stopped")
        ])

      assert {summary.provisioned_cpus, summary.provisioned_memory_mb} == {8, 16_384}

      summary =
        Capacity.box_summary(vm_box(%{"cpus" => 16, "memory_mb" => 65_536}), [
          made_as.("container", cpu_limit: 2.0, memory_limit_mb: 4096)
        ])

      assert {summary.provisioned_cpus, summary.provisioned_memory_mb} == {2.0, 4096}
    end

    test "containers aren't counted as a VM on a box that now runs VMs" do
      env = %Environment{
        id: Ecto.UUID.generate(),
        box: %Box{isolation: "vm"},
        created_once: true,
        isolation: "container",
        memory_limit_mb: 2048
      }

      assert %{memory_mb: 2048, source: :limits} = Capacity.provisioned(env, repo_fixture())

      # One from before isolation was recorded was made as containers.
      assert %{source: :limits} = Capacity.provisioned(%{env | isolation: nil}, repo_fixture())
    end
  end

  describe "check_placement/4" do
    setup do
      box = box_fixture(capacity: %{"cpus" => 16, "memory_mb" => 32_768})
      %{box: box}
    end

    test "fits", %{box: box} do
      assert :ok =
               Capacity.check_placement(box, [], repo_fixture(host_requirements: %{"cpus" => 4}))
    end

    test "a repo that wants more than the box has", %{box: box} do
      repo = repo_fixture(host_requirements: %{"cpus" => 32})
      assert {:contention, message} = Capacity.check_placement(box, [], repo)
      assert message =~ "32 CPUs"
    end

    test "past the threshold with what's already provisioned", %{box: box} do
      repo = repo_fixture(host_requirements: %{"cpus" => 8, "memory" => "8gb"})

      running =
        for _ <- 1..2,
            do: %Environment{
              id: Ecto.UUID.generate(),
              observed_state: "running",
              repo: repo,
              host_requirements: repo.host_requirements
            }

      assert {:contention, message} = Capacity.check_placement(box, running, repo)
      assert message =~ "past 90%"

      assert {:refuse, _} =
               Capacity.check_placement(%{box | capacity_policy: "refuse"}, running, repo)

      assert {:warn, _} =
               Capacity.check_placement(%{box | capacity_policy: "warn"}, running, repo)
    end
  end
end
