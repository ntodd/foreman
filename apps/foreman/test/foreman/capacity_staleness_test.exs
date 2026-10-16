defmodule Foreman.CapacityStalenessTest do
  @moduledoc "Usage figures from a box that has stopped reporting."
  use Foreman.DataCase

  import Foreman.Fixtures

  alias Foreman.Capacity
  alias Foreman.Capacity.Tracker

  defp stats(envs), do: %{capacity: %{cpus: 16, memory_mb: 65_536}, environments: envs}

  setup do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id, capacity: %{"cpus" => 16, "memory_mb" => 65_536})
    env = environment_fixture(box: box, user: user)
    %{box: box, env: env}
  end

  defp summary(box), do: Capacity.box_summary(box, Foreman.Environments.live_for_box(box.id))

  test "an offline box's last report doesn't count as current usage", %{box: box, env: env} do
    two_hours_ago = System.system_time(:second) - 7_200

    Tracker.record(
      box.id,
      stats(%{env.id => %{cpu_percent: 1_500.0, memory_mb: 60_000}}),
      two_hours_ago
    )

    summary = summary(box)
    assert summary.used_cpus == 0
    assert summary.used_memory_mb == 0
    refute summary.contention
    assert summary.reported_at == nil
  end

  test "a report from the last minute counts", %{box: box, env: env} do
    Tracker.record(
      box.id,
      stats(%{env.id => %{cpu_percent: 1_500.0, memory_mb: 60_000}}),
      System.system_time(:second) - 30
    )

    summary = summary(box)
    assert summary.used_cpus == 15.0
    assert summary.contention
  end

  test "an environment's latest usage goes stale too", %{box: box, env: env} do
    Tracker.record(
      box.id,
      stats(%{env.id => %{cpu_percent: 50.0, memory_mb: 512}}),
      System.system_time(:second) - 600
    )

    assert Tracker.latest_usage(env.id) == nil

    Tracker.record(box.id, stats(%{env.id => %{cpu_percent: 25.0, memory_mb: 256}}))
    assert %{cpu_percent: 25.0} = Tracker.latest_usage(env.id)
  end
end
