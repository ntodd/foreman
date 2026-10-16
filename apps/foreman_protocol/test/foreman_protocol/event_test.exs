defmodule ForemanProtocol.EventTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Event

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @op_id "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  test "op.log carries a stream and data" do
    assert {:ok, event} =
             Event.new("op.log", %{op_id: @op_id, stream: "stdout", data: "Step 1/3\n"})

    assert event.payload == %{op_id: @op_id, stream: "stdout", data: "Step 1/3\n"}
    assert {:ok, ^event} = event |> Event.to_wire() |> Event.from_wire()
  end

  test "op.result is ok or error" do
    assert {:ok, _} =
             Event.new("op.result", %{
               op_id: @op_id,
               status: "ok",
               result: %{"container_id" => "abc"}
             })

    assert {:ok, _} = Event.new("op.result", %{op_id: @op_id, status: "error", error: "boom"})
    assert {:error, _} = Event.new("op.result", %{op_id: @op_id, status: "maybe"})
  end

  test "box.inventory lists environments found by label" do
    payload = %{
      environments: [
        %{
          env_id: @env_id,
          slug: "storefront-2",
          state: "running",
          containers: [%{id: "abc", service: "app", state: "running"}]
        }
      ]
    }

    assert {:ok, event} = Event.new("box.inventory", payload)
    assert [%{state: "running", containers: [%{service: "app"}]}] = event.payload.environments
  end

  test "box.stats reports capacity and per-environment usage" do
    payload = %{
      capacity: %{cpus: 16, memory_mb: 65_536, disk_mb: 1_000_000, disk_free_mb: 400_000},
      environments: %{@env_id => %{cpu_percent: 123.5, memory_mb: 2048}}
    }

    assert {:ok, event} = Event.new("box.stats", payload)
    assert event.payload.capacity.cpus == 16
    assert event.payload.environments[@env_id].cpu_percent == 123.5
  end

  test "box.stats rejects environment keys that are not UUIDs" do
    payload = %{
      capacity: %{cpus: 1, memory_mb: 1, disk_mb: 1, disk_free_mb: 1},
      environments: %{"x" => %{}}
    }

    assert {:error, _} = Event.new("box.stats", payload)
  end

  test "box.metrics reports host usage at a point in time" do
    payload = %{
      at: 1_760_500_000,
      cpu_percent: 37.5,
      load1: 0.42,
      memory_total_mb: 16_000,
      memory_used_mb: 6_000,
      swap_total_mb: 2_048,
      swap_used_mb: 10,
      disk_total_mb: 100_000,
      disk_used_mb: 40_000
    }

    assert {:ok, event} = Event.new("box.metrics", payload)
    assert event.payload.cpu_percent == 37.5
    assert event.payload.memory_used_mb == 6_000
  end

  test "box.metrics defaults swap and load, and needs a time" do
    payload = %{
      at: 1_760_500_000,
      cpu_percent: 1,
      memory_total_mb: 1,
      memory_used_mb: 1,
      disk_total_mb: 1,
      disk_used_mb: 1
    }

    assert {:ok, %{payload: %{swap_used_mb: 0, load1: 0}}} = Event.new("box.metrics", payload)
    assert {:error, _} = Event.new("box.metrics", Map.delete(payload, :at))
  end

  test "env.state reports an observed state change" do
    assert {:ok, _} = Event.new("env.state", %{env_id: @env_id, state: "stopped"})
    assert {:error, _} = Event.new("env.state", %{env_id: @env_id, state: "exploded"})
  end

  test "rejects unknown event types" do
    assert {:error, {:unknown_type, "op.exec"}} = Event.new("op.exec", %{})
  end

  describe "untrusted text" do
    test "op.log and op.result refuse bytes that aren't UTF-8, so every accepted event encodes" do
      split_euro = <<0xE2, 0x82>>

      assert {:error, [{"data", "must be UTF-8"}]} =
               Event.new("op.log", %{op_id: @op_id, stream: "stdout", data: "€ " <> split_euro})

      assert {:error, [{"error", "must be UTF-8"}]} =
               Event.new("op.result", %{op_id: @op_id, status: "error", error: <<"bad ", 0xFF>>})
    end

    test "a list of many bad items is rejected in linear time" do
      bad = List.duplicate(1, 40_000)
      {us, result} = :timer.tc(fn -> Event.new("box.inventory", %{environments: bad}) end)

      assert {:error, errors} = result
      assert length(errors) == 40_000
      assert {"environments", "item 0 must be an object"} = hd(errors)
      assert us < 500_000, "rejecting 40k bad items took #{div(us, 1000)} ms"
    end
  end
end
