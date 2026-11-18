defmodule ForemanWeb.ClientIPTest do
  use ExUnit.Case, async: true

  alias ForemanWeb.ClientIP

  test "a direct client is its peer address" do
    assert ClientIP.resolve({100, 64, 0, 7}, []) == "100.64.0.7"
  end

  test "behind a local proxy (tailscale serve), the address the proxy appended is the client" do
    # A client can send its own X-Forwarded-For; the proxy appends the real
    # address, so only the last entry is trusted.
    headers = [{"x-forwarded-for", "6.6.6.6, 100.64.0.9"}]
    assert ClientIP.resolve({127, 0, 0, 1}, headers) == "100.64.0.9"

    assert ClientIP.resolve({0, 0, 0, 0, 0, 0, 0, 1}, [{"X-Forwarded-For", "fd7a::5"}]) ==
             "fd7a::5"
  end

  test "forwarded headers from anyone but a local proxy are ignored" do
    assert ClientIP.resolve({100, 64, 0, 7}, [{"x-forwarded-for", "1.2.3.4"}]) == "100.64.0.7"
  end

  test "a forwarded value that isn't an address falls back to the peer" do
    for junk <- ["", "  ", "unknown", "1.2.3.4.5", "<script>"] do
      assert ClientIP.resolve({127, 0, 0, 1}, [{"x-forwarded-for", junk}]) == "127.0.0.1"
    end
  end

  test "works from a conn and from socket connect info" do
    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"x-forwarded-for", "100.64.0.3"}]
    }

    assert ClientIP.from_conn(conn) == "100.64.0.3"

    info = %{
      peer_data: %{address: {127, 0, 0, 1}},
      x_headers: [{"x-forwarded-for", "100.64.0.4"}]
    }

    assert ClientIP.from_connect_info(info) == "100.64.0.4"
    assert ClientIP.from_connect_info(%{}) == "unknown"
  end

  # In the Docker image, tailscale serve reaches the published loopback
  # port and Docker hands the connection over from the bridge's gateway,
  # so the peer is never loopback.
  describe "configured proxies" do
    test "a peer in a trusted range has its forwarded address believed" do
      headers = [{"x-forwarded-for", "100.64.0.9"}]
      trusted = ClientIP.parse_trusted(["172.16.0.0/12", "10.1.2.3"])

      assert ClientIP.resolve({172, 18, 0, 1}, headers, trusted) == "100.64.0.9"
      assert ClientIP.resolve({10, 1, 2, 3}, headers, trusted) == "100.64.0.9"

      assert ClientIP.resolve({0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 1}, headers, trusted) ==
               "100.64.0.9"

      assert ClientIP.resolve({10, 1, 2, 4}, headers, trusted) == "10.1.2.4"
      assert ClientIP.resolve({192, 168, 1, 1}, headers, trusted) == "192.168.1.1"
    end

    test "gateway is the default route's gateway" do
      route = """
      Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
      eth0\t00000000\t010012AC\t0003\t0\t0\t0\t00000000\t0\t0\t0
      eth0\t000012AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0
      """

      trusted = ClientIP.parse_trusted(["gateway"], route)

      assert ClientIP.resolve({172, 18, 0, 1}, [{"x-forwarded-for", "100.64.0.9"}], trusted) ==
               "100.64.0.9"

      assert ClientIP.resolve({172, 18, 0, 2}, [{"x-forwarded-for", "100.64.0.9"}], trusted) ==
               "172.18.0.2"

      # No default route (or no /proc): nothing extra is trusted.
      assert ClientIP.parse_trusted(["gateway"], "") == []
    end

    test "an entry that isn't an address or a range is refused" do
      for bad <- ["nope", "10.0.0.0/33", "300.1.1.1", "fd00::/129"] do
        assert_raise ArgumentError, fn -> ClientIP.parse_trusted([bad]) end
      end
    end
  end
end
