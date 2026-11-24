defmodule ForemanProtocol.AuthTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Auth

  @agent_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup do
    {public, private} = Auth.generate_keypair()
    %{public: public, private: private}
  end

  test "keys are 32-byte ed25519 keys", %{public: public, private: private} do
    assert byte_size(public) == 32
    assert byte_size(private) == 32
  end

  test "a signed connect header verifies", %{public: public, private: private} do
    headers = Auth.connect_headers(@agent_id, private, now: 1_000)
    assert %{"x-foreman-agent-id" => @agent_id} = headers

    assert {:ok, %{agent_id: @agent_id, nonce: nonce, public_key: ^public}} =
             Auth.verify_connect_headers(headers, fn @agent_id -> {:ok, public} end, now: 1_030)

    assert byte_size(nonce) > 0
  end

  test "rejects stale and future timestamps", %{public: public, private: private} do
    headers = Auth.connect_headers(@agent_id, private, now: 1_000)
    lookup = fn _ -> {:ok, public} end

    assert {:error, :clock_skew} = Auth.verify_connect_headers(headers, lookup, now: 1_061)
    assert {:error, :clock_skew} = Auth.verify_connect_headers(headers, lookup, now: 939)
  end

  test "rejects a signature made by another key", %{public: public} do
    {_other_public, other_private} = Auth.generate_keypair()
    headers = Auth.connect_headers(@agent_id, other_private, now: 1_000)

    assert {:error, :bad_signature} =
             Auth.verify_connect_headers(headers, fn _ -> {:ok, public} end, now: 1_000)
  end

  test "rejects tampered fields", %{public: public, private: private} do
    headers = Auth.connect_headers(@agent_id, private, now: 1_000)
    lookup = fn _ -> {:ok, public} end

    tampered = Map.put(headers, "x-foreman-agent-ts", "1001")
    assert {:error, :bad_signature} = Auth.verify_connect_headers(tampered, lookup, now: 1_000)

    tampered = Map.put(headers, "x-foreman-agent-nonce", String.duplicate("n", 24))
    assert {:error, :bad_signature} = Auth.verify_connect_headers(tampered, lookup, now: 1_000)
  end

  test "rejects unknown agents and malformed headers", %{private: private} do
    headers = Auth.connect_headers(@agent_id, private, now: 1_000)

    assert {:error, :unknown_agent} =
             Auth.verify_connect_headers(headers, fn _ -> :error end, now: 1_000)

    assert {:error, :malformed} = Auth.verify_connect_headers(%{}, fn _ -> :error end, now: 1_000)

    bad = Map.put(headers, "x-foreman-agent-sig", "not base64!!")

    assert {:error, :malformed} =
             Auth.verify_connect_headers(bad, fn _ -> {:ok, "x"} end, now: 1_000)
  end

  describe "release signatures" do
    test "verify a release manifest" do
      {public, private} = Auth.generate_keypair()
      sha = String.duplicate("ab", 32)
      sig = Auth.sign_release("0.2.0", "linux-arm64", sha, private)

      assert :ok = Auth.verify_release("0.2.0", "linux-arm64", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("0.2.1", "linux-arm64", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("0.2.0", "linux-amd64", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("0.2.0", "linux-arm64", sha, "x", public)
    end
  end

  describe "a request a box relays for one of its environments" do
    @env_id "0b5c2f6e-1d6f-4f6b-9b7e-0c9e4f0a1b2c"
    @target "/api/agents/relay/v1/secrets/environment/" <> @env_id <> "?limit=5"

    defp request(overrides \\ %{}) do
      Map.merge(
        %{environment: @env_id, method: "PATCH", target: @target, body: ~s({"unset":["A"]})},
        overrides
      )
    end

    defp seen(request) do
      %{
        method: request.method,
        target: request.target,
        body_sha256: :crypto.hash(:sha256, request.body),
        idempotency_key: request[:idempotency_key]
      }
    end

    test "verifies, and names the environment the box signed for", ctx do
      headers = Auth.relay_headers(@agent_id, ctx.private, request(), now: 1_000)
      assert headers["x-foreman-environment"] == @env_id
      lookup = fn @agent_id -> {:ok, ctx.public} end

      assert {:ok, %{agent_id: @agent_id, environment: @env_id, nonce: nonce}} =
               Auth.verify_relay_headers(headers, lookup, seen(request()), now: 1_030)

      assert byte_size(nonce) >= 16
    end

    test "is refused when anything it covers differs from what arrived", ctx do
      headers = Auth.relay_headers(@agent_id, ctx.private, request(), now: 1_000)
      lookup = fn _ -> {:ok, ctx.public} end
      other_env = "9d2c7b1a-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

      for changed <- [
            %{method: "GET"},
            %{target: String.replace(@target, @env_id, other_env)},
            %{target: @target <> "&scope=user"},
            %{body: ~s({"unset":["B"]})},
            %{body: ""}
          ] do
        assert {:error, :bad_signature} =
                 Auth.verify_relay_headers(headers, lookup, seen(request(changed)), now: 1_000)
      end

      for {header, value} <- [
            {"x-foreman-environment", other_env},
            {"x-foreman-agent-ts", "1001"},
            {"x-foreman-agent-nonce", String.duplicate("n", 24)}
          ] do
        assert {:error, :bad_signature} =
                 Auth.verify_relay_headers(
                   Map.put(headers, header, value),
                   lookup,
                   seen(request()),
                   now: 1_000
                 )
      end
    end

    test "covers the idempotency key, and whether there is one", ctx do
      lookup = fn _ -> {:ok, ctx.public} end
      keyed = request(%{idempotency_key: "k-1"})
      headers = Auth.relay_headers(@agent_id, ctx.private, keyed, now: 1_000)

      assert {:ok, _} = Auth.verify_relay_headers(headers, lookup, seen(keyed), now: 1_000)

      for other <- ["k-2", nil, ""] do
        assert {:error, _} =
                 Auth.verify_relay_headers(
                   headers,
                   lookup,
                   seen(%{keyed | idempotency_key: other}),
                   now: 1_000
                 )
      end

      bare = Auth.relay_headers(@agent_id, ctx.private, request(), now: 1_000)

      assert {:error, :bad_signature} =
               Auth.verify_relay_headers(bare, lookup, seen(keyed), now: 1_000)

      for bad <- ["a b", "a\nb", "", String.duplicate("k", 256)] do
        assert_raise ArgumentError, fn ->
          Auth.relay_headers(@agent_id, ctx.private, request(%{idempotency_key: bad}), now: 1_000)
        end
      end
    end

    test "is refused when stale, from an unknown box or signed by another key", ctx do
      headers = Auth.relay_headers(@agent_id, ctx.private, request(), now: 1_000)
      seen = seen(request())

      assert {:error, :clock_skew} =
               Auth.verify_relay_headers(headers, fn _ -> {:ok, ctx.public} end, seen, now: 1_061)

      assert {:error, :unknown_agent} =
               Auth.verify_relay_headers(headers, fn _ -> :error end, seen, now: 1_000)

      {other_public, _} = Auth.generate_keypair()

      assert {:error, :bad_signature} =
               Auth.verify_relay_headers(headers, fn _ -> {:ok, other_public} end, seen,
                 now: 1_000
               )
    end

    test "a connect signature isn't a relay signature, nor the other way round", ctx do
      lookup = fn _ -> {:ok, ctx.public} end
      relay = Auth.relay_headers(@agent_id, ctx.private, request(), now: 1_000)
      connect = Auth.connect_headers(@agent_id, ctx.private, now: 1_000)

      assert {:error, :bad_signature} = Auth.verify_connect_headers(relay, lookup, now: 1_000)

      assert {:error, _} =
               Auth.verify_relay_headers(
                 Map.put(connect, "x-foreman-environment", @env_id),
                 lookup,
                 seen(request()),
                 now: 1_000
               )
    end

    test "fields that could run into each other are refused, signing or verifying", ctx do
      lookup = fn _ -> {:ok, ctx.public} end

      for bad <- [
            %{environment: "not-a-uuid"},
            %{environment: @env_id <> "\nGET"},
            %{method: "GET\n/x"},
            %{method: "get"},
            %{target: "/a\n/b"},
            %{target: "relative"}
          ] do
        assert_raise ArgumentError, fn ->
          Auth.relay_headers(@agent_id, ctx.private, request(bad), now: 1_000)
        end
      end

      headers = Auth.relay_headers(@agent_id, ctx.private, request(), now: 1_000)

      assert {:error, :malformed} =
               Auth.verify_relay_headers(
                 Map.put(headers, "x-foreman-environment", "not-a-uuid"),
                 lookup,
                 seen(request()),
                 now: 1_000
               )

      assert {:error, :malformed} =
               Auth.verify_relay_headers(
                 Map.delete(headers, "x-foreman-environment"),
                 lookup,
                 seen(request()),
                 now: 1_000
               )

      assert {:error, :malformed} =
               Auth.verify_relay_headers(
                 headers,
                 lookup,
                 %{seen(request()) | body_sha256: "short"},
                 now: 1_000
               )
    end
  end
end
