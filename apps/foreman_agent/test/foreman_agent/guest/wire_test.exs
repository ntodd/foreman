defmodule ForemanAgent.Guest.WireTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Guest.Wire

  test "a log chunk survives the trip, bytes and all" do
    data = <<"building\n", 0xFF, 0x00, "tail">>
    {events, _} = Wire.feed(Wire.decoder(), Wire.log("stdout", data))
    assert events == [{:log, "stdout", data}]
  end

  test "results and errors come back as the runner returned them" do
    {events, _} = Wire.feed(Wire.decoder(), Wire.result({:ok, %{"container_id" => "abc"}}))
    assert events == [{:result, {:ok, %{"container_id" => "abc"}}}]

    {events, _} = Wire.feed(Wire.decoder(), Wire.result({:error, "devcontainer up failed"}))
    assert events == [{:result, {:error, "devcontainer up failed"}}]
  end

  test "events split across chunks are put back together" do
    line = Wire.log("info", "hello\n") <> Wire.result({:ok, %{}})
    {a, b} = String.split_at(line, 7)
    {first, decoder} = Wire.feed(Wire.decoder(), a)
    {second, _} = Wire.feed(decoder, b)
    assert first == []
    assert second == [{:log, "info", "hello\n"}, {:result, {:ok, %{}}}]
  end

  test "anything else the guest prints is kept as noise, not trusted" do
    noisy = "erl_child_setup: warning\n" <> Wire.result({:ok, %{}})
    {events, _} = Wire.feed(Wire.decoder(), noisy)
    assert events == [{:noise, "erl_child_setup: warning"}, {:result, {:ok, %{}}}]
  end

  test "a marked line that doesn't decode is noise" do
    {events, _} = Wire.feed(Wire.decoder(), "\x1eFM {not json\n")
    assert [{:noise, _}] = events
  end

  test "a result that isn't a map or a message is noise" do
    {events, _} = Wire.feed(Wire.decoder(), ~s(\x1eFM {"ok":[1,2]}\n))
    assert [{:noise, _}] = events
  end

  test "a request round-trips, validated again on the way in" do
    {:ok, cmd} =
      ForemanProtocol.Command.new("env.secrets.write", %{
        "env_id" => "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f",
        "files" => %{"secrets.env" => "A=1\n"}
      })

    request = Wire.request("env.secrets.write", cmd.payload)
    # JSON, not an Erlang term: the guest decodes it without trusting it.
    assert {:ok, _} = JSON.decode(request)
    assert {:ok, {"env.secrets.write", payload}} = Wire.decode_request(request)
    assert payload == cmd.payload
  end

  test "a request the protocol wouldn't accept is refused" do
    bad = JSON.encode!(%{"type" => "env.secrets.write", "payload" => %{"env_id" => "nope"}})
    assert {:error, :invalid_request} = Wire.decode_request(bad)
    assert {:error, :invalid_request} = Wire.decode_request("garbage")
  end
end
