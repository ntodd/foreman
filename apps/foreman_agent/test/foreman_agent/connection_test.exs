defmodule ForemanAgent.ConnectionTest do
  # Uses the application's Outbox, so not async.
  use ExUnit.Case, async: false

  alias ForemanAgent.{Connection, Outbox}
  alias ForemanProtocol.Event
  alias Slipstream.Commands.JoinTopic

  @topic "agent:6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  defp closed_socket do
    config = Slipstream.Configuration.validate!(uri: "ws://127.0.0.1:1/agent/websocket")
    socket = %{Slipstream.Socket.new() | channel_config: config}
    socket = Slipstream.Socket.put_join_config(socket, @topic, %{"in_flight" => ["stale"]})
    put_in(socket.joins[@topic].status, :closed)
  end

  describe "a refused or closed channel" do
    test "is rejoined with a growing backoff" do
      reason = {:failed_to_join, %{"reason" => "unsupported protocol version"}}

      socket =
        Enum.reduce(1..3, closed_socket(), fn _, socket ->
          {:ok, socket} = Connection.handle_topic_close(@topic, reason, socket)
          assert_receive {:__slipstream_command__, %JoinTopic{topic: @topic}}, 5_000
          put_in(socket.joins[@topic].status, :closed)
        end)

      assert socket.joins[@topic].rejoin_counter == 3
    end

    test "is rejoined with the current in-flight operations, not the first join's" do
      {:ok, _socket} = Connection.handle_topic_close(@topic, :closed, closed_socket())
      assert_receive {:__slipstream_command__, %JoinTopic{payload: payload}}, 5_000
      refute "stale" in payload["in_flight"]
    end
  end

  test "a result the control plane refuses isn't redelivered on every connect" do
    {:ok, event} =
      Event.new("op.result", %{op_id: ForemanProtocol.uuid(), status: "ok"})

    :ok = Outbox.attach(self())
    Outbox.push(event)
    assert_receive {:outbox_deliver, ^event, ack_id}

    ref = make_ref()
    socket = Slipstream.Socket.assign(closed_socket(), :acks, %{ref => ack_id})
    {:ok, _} = Connection.handle_reply(ref, {:error, %{"reason" => "unknown operation"}}, socket)

    :ok = Outbox.detach()
    :ok = Outbox.attach(self())
    refute_receive {:outbox_deliver, ^event, _}, 200
    :ok = Outbox.detach()
  end
end
