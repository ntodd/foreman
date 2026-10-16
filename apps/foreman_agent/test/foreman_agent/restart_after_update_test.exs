defmodule ForemanAgent.RestartAfterUpdateTest do
  # After installing an update the agent exits so systemd starts the new
  # release. It waits for running operations and unacknowledged results
  # first: exiting kills builds and loses results.
  use ExUnit.Case, async: true

  alias ForemanAgent.{Handler, Outbox}
  alias ForemanProtocol.Event

  describe "Outbox.settled?" do
    setup do
      %{outbox: start_supervised!({Outbox, name: nil})}
    end

    defp result do
      {:ok, e} = Event.new("op.result", %{op_id: ForemanProtocol.uuid(), status: "ok"})
      e
    end

    test "is true with nothing to deliver", %{outbox: outbox} do
      assert Outbox.settled?(outbox)
    end

    test "is false until results are acknowledged", %{outbox: outbox} do
      Outbox.push(outbox, result())
      refute Outbox.settled?(outbox)

      Outbox.attach(outbox, self())
      assert_receive {:outbox_deliver, _, ack_id}
      refute Outbox.settled?(outbox)

      Outbox.ack(outbox, ack_id)
      assert Outbox.settled?(outbox)
    end
  end

  describe "await_idle" do
    test "returns once nothing is busy" do
      counter = :counters.new(1, [])

      busy? = fn ->
        :counters.add(counter, 1, 1)
        :counters.get(counter, 1) < 3
      end

      assert Handler.await_idle(busy?, 10, 5_000) == :idle
      assert :counters.get(counter, 1) == 3
    end

    test "gives up at the deadline" do
      assert Handler.await_idle(fn -> true end, 10, 50) == :timeout
    end
  end
end
