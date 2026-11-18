defmodule ForemanWeb.ClientIP do
  @moduledoc """
  The address a request really came from, for rate limits and logs.

  The control plane usually sits behind `tailscale serve`, which appends
  the client's address to `X-Forwarded-For`. That last entry is trusted,
  but only from a peer that can only be the proxy: loopback, or an
  address in `FOREMAN_TRUSTED_PROXIES`. Anyone else could send whatever
  header they like.

  In the Docker image the peer is never loopback: `tailscale serve`
  reaches the port published on the host's loopback, and Docker hands the
  connection to the container from the bridge network's gateway. The
  image sets `FOREMAN_TRUSTED_PROXIES=gateway`, the container's default
  gateway, which only the host's own connections come from.
  """

  @type range :: {:inet.ip_address(), non_neg_integer()}

  @spec from_conn(Plug.Conn.t()) :: String.t()
  def from_conn(%Plug.Conn{remote_ip: ip, req_headers: headers}), do: resolve(ip, headers)

  @spec from_connect_info(map()) :: String.t()
  def from_connect_info(%{peer_data: %{address: ip}} = info),
    do: resolve(ip, info[:x_headers] || [])

  def from_connect_info(_), do: "unknown"

  @spec resolve(:inet.ip_address(), [{String.t(), String.t()}], [range()]) :: String.t()
  def resolve(peer, headers, trusted \\ trusted()) do
    with true <- loopback?(peer) or Enum.any?(trusted, &in_range?(peer, &1)),
         {:ok, forwarded} <- last_forwarded(headers) do
      forwarded |> :inet.ntoa() |> to_string()
    else
      _ -> peer |> :inet.ntoa() |> to_string()
    end
  end

  # Parsed once: `gateway` is read from the routing table at first use.
  defp trusted do
    case :persistent_term.get({__MODULE__, :trusted}, nil) do
      nil ->
        ranges = parse_trusted(Application.get_env(:foreman, :trusted_proxies, []))
        :persistent_term.put({__MODULE__, :trusted}, ranges)
        ranges

      ranges ->
        ranges
    end
  end

  @doc """
  Parses `FOREMAN_TRUSTED_PROXIES` entries: an address, a CIDR range, or
  `gateway` (the default route's gateway, from `route_table`, which is
  /proc/net/route's contents). Raises on anything else.
  """
  @spec parse_trusted([String.t()], String.t() | nil) :: [range()]
  def parse_trusted(entries, route_table \\ nil) do
    Enum.flat_map(entries, fn
      "gateway" -> default_gateway(route_table || read_route_table())
      entry -> [parse_range(entry)]
    end)
  end

  defp parse_range(entry) do
    {address, bits} =
      case String.split(entry, "/", parts: 2) do
        [address, bits] -> {address, Integer.parse(bits)}
        [address] -> {address, :host}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         max = if(tuple_size(ip) == 4, do: 32, else: 128),
         {:ok, bits} <- prefix(bits, max) do
      {ip, bits}
    else
      _ -> raise ArgumentError, "not an address or a CIDR range: #{inspect(entry)}"
    end
  end

  defp prefix(:host, max), do: {:ok, max}
  defp prefix({bits, ""}, max) when bits >= 0 and bits <= max, do: {:ok, bits}
  defp prefix(_, _max), do: :error

  defp read_route_table do
    case File.read("/proc/net/route") do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  # /proc/net/route gives addresses as little-endian hex.
  defp default_gateway(route_table) do
    route_table
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.map(&String.split(&1, "\t", trim: true))
    |> Enum.find_value([], fn
      [_iface, "00000000", gateway | _] when gateway != "00000000" ->
        case Base.decode16(gateway, case: :mixed) do
          {:ok, <<a, b, c, d>>} -> [{{d, c, b, a}, 32}]
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp in_range?(peer, {network, bits}) do
    case {unmap(peer), network} do
      {{_, _, _, _} = ip, {_, _, _, _}} ->
        same_prefix?(ip, network, bits, 8)

      {{_, _, _, _, _, _, _, _} = ip, {_, _, _, _, _, _, _, _}} ->
        same_prefix?(ip, network, bits, 16)

      _ ->
        false
    end
  end

  defp same_prefix?(ip, network, bits, width) do
    <<a::bitstring-size(^bits), _::bitstring>> = to_bits(ip, width)
    <<b::bitstring-size(^bits), _::bitstring>> = to_bits(network, width)
    a == b
  end

  defp to_bits(ip, width),
    do: ip |> Tuple.to_list() |> Enum.map_join(&<<&1::size(width)>>)

  # An IPv4 client on a dual-stack listener arrives as ::ffff:a.b.c.d.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}

  defp unmap(ip), do: ip

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: Bitwise.bsr(a, 8) == 127
  defp loopback?(_), do: false

  defp last_forwarded(headers) do
    value =
      Enum.find_value(headers, fn {k, v} -> String.downcase(k) == "x-forwarded-for" && v end)

    with value when is_binary(value) <- value,
         true <- String.valid?(value),
         last when last != "" <- value |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(last)) do
      {:ok, ip}
    else
      _ -> :error
    end
  end
end
