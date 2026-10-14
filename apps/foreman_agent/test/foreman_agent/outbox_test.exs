defmodule ForemanAgent.OutboxTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Outbox
  alias ForemanProtocol.Event

  @op "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  setup do
    outbox = start_supervised!({Outbox, name: nil, max_logs: 3})
    %{outbox: outbox}
  end

  defp event(type, payload) do
    {:ok, e} = Event.new(type, payload)
    e
  end

  defp log(n), do: event("op.log", %{op_id: @op, stream: "info", data: "line #{n}\n"})
  defp result, do: event("op.result", %{op_id: @op, status: "ok"})

  test "delivers straight away to an attached connection", %{outbox: outbox} do
    Outbox.attach(outbox, self())
    Outbox.push(outbox, log(1))
    assert_receive {:outbox_deliver, %Event{type: "op.log"}, nil}
  end

  test "buffers while detached and flushes in order on attach", %{outbox: outbox} do
    Outbox.push(outbox, log(1))
    Outbox.push(outbox, result())
    refute_receive {:outbox_deliver, _, _}, 20

    Outbox.attach(outbox, self())
    assert_receive {:outbox_deliver, %Event{type: "op.log"}, nil}
    assert_receive {:outbox_deliver, %Event{type: "op.result"}, ack_id}
    assert is_integer(ack_id)
  end

  test "keeps results until acked, and redelivers them on the next attach", %{outbox: outbox} do
    Outbox.attach(outbox, self())
    Outbox.push(outbox, result())
    assert_receive {:outbox_deliver, %Event{type: "op.result"}, ack_id}

    Outbox.detach(outbox)
    Outbox.attach(outbox, self())
    assert_receive {:outbox_deliver, %Event{type: "op.result"}, ^ack_id}

    Outbox.ack(outbox, ack_id)
    Outbox.detach(outbox)
    Outbox.attach(outbox, self())
    refute_receive {:outbox_deliver, _, _}, 20
  end

  test "drops the oldest logs past the limit but never results", %{outbox: outbox} do
    for n <- 1..5, do: Outbox.push(outbox, log(n))
    Outbox.push(outbox, result())

    Outbox.attach(outbox, self())

    datas =
      for _ <- 1..3 do
        assert_receive {:outbox_deliver, %Event{type: "op.log", payload: %{data: data}}, nil}
        data
      end

    assert datas == ["line 3\n", "line 4\n", "line 5\n"]
    assert_receive {:outbox_deliver, %Event{type: "op.result"}, _}
  end

  test "detaches when the connection process dies", %{outbox: outbox} do
    conn = spawn(fn -> Process.sleep(:infinity) end)
    Outbox.attach(outbox, conn)
    Process.exit(conn, :kill)
    Process.sleep(10)

    Outbox.push(outbox, result())
    Outbox.attach(outbox, self())
    assert_receive {:outbox_deliver, %Event{type: "op.result"}, _}
  end
end
