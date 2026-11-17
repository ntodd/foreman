defmodule Foreman.CapacityTest do
  use Foreman.DataCase

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

  describe "box_summary/2" do
    setup do
      box =
        box_fixture(
          capacity: %{"cpus" => 16, "memory_mb" => 32_768},
          cpu_threshold: 4.0,
          memory_threshold: 0.9
        )

      %{box: box}
    end

    defp limited(cpus, memory_mb) do
      %Environment{
        id: Ecto.UUID.generate(),
        observed_state: "running",
        cpu_limit: cpus,
        memory_limit_mb: memory_mb,
        repo: repo_fixture()
      }
    end

    test "checks CPU and memory against their own thresholds", %{box: box} do
      # 32 CPUs is 2x the box, under its 4x; 16 GB is under 90%.
      envs = [limited(16, 8192), limited(16, 8192)]
      refute Capacity.box_summary(box, envs).contention

      # 64 GB is past 90% of 32.
      envs = [limited(1, 32_768), limited(1, 32_768)]
      assert Capacity.box_summary(box, envs).contention

      # 72 CPUs is past 4x.
      envs = for _ <- 1..9, do: limited(8, 1024)
      assert Capacity.box_summary(box, envs).contention
    end

    test "a busy box is in contention even when its CPU threshold is past 100%", %{box: box} do
      env = limited(4, 1024)

      Tracker.record(box.id, %{
        capacity: %{},
        environments: %{env.id => %{cpu_percent: 1500.0, memory_mb: 1024}}
      })

      # 15 of 16 cores busy: past 90%, though nowhere near 4x.
      assert Capacity.box_summary(box, [env]).contention
    end

    test "a busy box under a threshold below 90% still uses that threshold", %{box: box} do
      box = %{box | cpu_threshold: 0.5}
      env = limited(1, 1024)

      Tracker.record(box.id, %{
        capacity: %{},
        environments: %{env.id => %{cpu_percent: 900.0, memory_mb: 1024}}
      })

      assert Capacity.box_summary(box, [env]).contention
    end
  end

  describe "used_threshold/1" do
    test "is the threshold, or 90% when the threshold is higher" do
      assert Capacity.used_threshold(0.5) == 0.5
      assert Capacity.used_threshold(0.9) == 0.9
      assert Capacity.used_threshold(4.0) == 0.9
    end
  end

  describe "check_placement/4" do
    setup do
      box = box_fixture(capacity: %{"cpus" => 16, "memory_mb" => 32_768})
      %{box: box}
    end

    test "says which resource is past its threshold", %{box: box} do
      box = %{box | cpu_threshold: 4.0, memory_threshold: 1.2}
      repo = repo_fixture()

      assert :ok =
               Capacity.check_placement(box, [], repo, %{cpu_limit: 32, memory_limit_mb: 32_768})

      assert {:contention, message} =
               Capacity.check_placement(box, [], repo, %{cpu_limit: 65, memory_limit_mb: 1024})

      assert message =~ "past 400% of its CPUs"
      refute message =~ "memory"

      assert {:contention, message} =
               Capacity.check_placement(box, [], repo, %{cpu_limit: 1, memory_limit_mb: 40_000})

      assert message =~ "past 120% of its memory"
      refute message =~ "CPUs"

      assert {:contention, message} =
               Capacity.check_placement(box, [], repo, %{cpu_limit: 65, memory_limit_mb: 40_000})

      assert message =~ "past 400% of its CPUs and 120% of its memory"
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
