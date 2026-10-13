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
