defmodule ForemanAgent.InventoryTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Inventory

  @e1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @e2 "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  defp container(id, env_id, slug, service, state) do
    %{
      "Id" => id,
      "State" => state,
      "Labels" => %{
        "foreman.env_id" => env_id,
        "foreman.slug" => slug,
        "com.docker.compose.service" => service
      }
    }
  end

  test "groups containers by environment and derives a state" do
    containers = [
      container("a1", @e1, "storefront-1", "app", "running"),
      container("a2", @e1, "storefront-1", "db", "running"),
      container("b1", @e2, "storefront-2", "app", "exited"),
      container("b2", @e2, "storefront-2", "db", "running")
    ]

    assert [
             %{env_id: @e2, slug: "storefront-2", state: "partial", containers: [_, _]},
             %{env_id: @e1, slug: "storefront-1", state: "running", containers: containers}
           ] = Enum.sort_by(Inventory.from_containers(containers), & &1.slug, :desc)

    assert %{id: "a1", service: "app", state: "running"} in containers
  end

  test "an environment with every container stopped is stopped" do
    containers = [
      container("a1", @e1, "storefront-1", "app", "exited"),
      container("a2", @e1, "storefront-1", "db", "created")
    ]

    assert [%{state: "stopped"}] = Inventory.from_containers(containers)
  end

  test "skips containers with labels that don't validate" do
    containers = [
      container("x", "../../etc", "storefront-1", "app", "running"),
      container("y", @e1, "Bad Slug", "app", "running")
    ]

    assert Inventory.from_containers(containers) == []
  end
end
