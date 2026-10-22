defmodule ForemanAgent.InventoryTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Inventory

  @e1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @e2 "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  defp container(id, env_id, slug, service, state, extra \\ []) do
    %{
      "Id" => id,
      "State" => state,
      "Status" => Keyword.get(extra, :status, ""),
      "Labels" =>
        Map.merge(
          %{
            "foreman.env_id" => env_id,
            "foreman.slug" => slug,
            "com.docker.compose.service" => service
          },
          if(extra[:devcontainer], do: %{"foreman.devcontainer" => "true"}, else: %{})
        )
    }
  end

  defp states(containers),
    do: containers |> Inventory.from_containers() |> Enum.map(& &1.state)

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

  describe "a container that ran to completion" do
    test "doesn't make a running environment partial" do
      assert states([
               container("a1", @e1, "clerkcast-1", "app", "running", devcontainer: true),
               container("a2", @e1, "clerkcast-1", "db", "running"),
               container("a3", @e1, "clerkcast-1", "s3-init", "exited",
                 status: "Exited (0) 3 hours ago"
               )
             ]) == ["running"]
    end

    test "is still partial when it failed" do
      assert states([
               container("a1", @e1, "clerkcast-1", "app", "running", devcontainer: true),
               container("a2", @e1, "clerkcast-1", "s3-init", "exited",
                 status: "Exited (1) 3 hours ago"
               )
             ]) == ["partial"]
    end

    test "doesn't count when it's the devcontainer" do
      assert states([
               container("a1", @e1, "clerkcast-1", "app", "exited",
                 devcontainer: true,
                 status: "Exited (0) 2 minutes ago"
               ),
               container("a2", @e1, "clerkcast-1", "db", "running")
             ]) == ["partial"]
    end

    test "leaves a stopped environment stopped" do
      # A stop leaves Postgres at 0 (it exits cleanly on SIGTERM) and the
      # devcontainer killed.
      assert states([
               container("a1", @e1, "clerkcast-1", "app", "exited",
                 devcontainer: true,
                 status: "Exited (137) 1 minute ago"
               ),
               container("a2", @e1, "clerkcast-1", "db", "exited",
                 status: "Exited (0) 1 minute ago"
               ),
               container("a3", @e1, "clerkcast-1", "s3-init", "exited",
                 status: "Exited (0) 3 hours ago"
               )
             ]) == ["stopped"]
    end

    test "is stopped when nothing else is left" do
      assert states([
               container("a1", @e1, "clerkcast-1", "s3-init", "exited",
                 status: "Exited (0) 3 hours ago"
               )
             ]) == ["stopped"]
    end
  end

  test "skips containers with labels that don't validate" do
    containers = [
      container("x", "../../etc", "storefront-1", "app", "running"),
      container("y", @e1, "Bad Slug", "app", "running")
    ]

    assert Inventory.from_containers(containers) == []
  end
end
