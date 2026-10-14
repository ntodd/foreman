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

    assert {:ok, %{agent_id: @agent_id, nonce: nonce}} =
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
end
