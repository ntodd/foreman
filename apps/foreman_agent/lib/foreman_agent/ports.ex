defmodule ForemanAgent.Ports do
  @moduledoc """
  The TCP ports listening in each running environment's devcontainer,
  for links to them on the environment's page.

  The agent reads the devcontainer's sockets from the box: Docker says
  which host pid the container's init is, and `/proc/<pid>/net/tcp` (and
  `tcp6`) lists every socket in its network namespace, which is the one
  on the tailnet. Nothing runs in the container for that, and anything
  that starts listening shows up.

  Tailscale runs in userspace mode and hands each connection from the
  tailnet to 127.0.0.1 or ::1 on the same port, so a listener on a
  loopback or any address is reachable, and one on any other address
  (tailscaled's own proxy on 127.0.0.2, a compose network) isn't.

  Which process holds a socket comes from the box too, from the fds of
  the container's processes. Only processes running as the agent's own
  uid can be read that way, which on Linux is the remote user's: the
  devcontainer CLI gives it the uid of the user that runs it. A listener
  running as anyone else (root's sshd, say) goes unnamed.
  """

  import Bitwise

  require Logger

  @listen "0A"
  # More than anyone runs by hand; keeps a misbehaving container from
  # filling the report.
  @max_ports 100
  @max_name 64
  # How many fds one lookup reads, across the container's processes,
  # before giving up on the rest: a container can hold any number.
  @fd_budget 20_000
  # Cached names are looked up again after this long, even for the same
  # sockets: one can change hands (a supervisor passing it to a new child).
  @names_ttl 60_000

  @type cache :: %{
          String.t() => {MapSet.t(integer()), %{integer() => String.t()}, integer()}
        }

  @doc """
  Each running environment's reachable ports, sorted, as
  `%{env_id => [%{port: 4000, process: "beam.smp"}]}`, with the cache of
  process names to pass back next time. An environment whose container
  can't be read is left out.
  """
  @spec collect(map(), cache(), integer()) :: {map(), cache()} | {:error, String.t()}
  def collect(ctx, cache, now \\ System.monotonic_time(:millisecond)) do
    case ctx.docker.list_containers(["foreman.env_id"]) do
      {:ok, containers} ->
        found =
          for c <- containers,
              devcontainer?(c),
              {:ok, listeners} <- [listeners(ctx, c["Id"])],
              do: {c["Labels"]["foreman.env_id"], c["Id"], listeners}

        cache = Map.take(cache, Enum.map(found, &elem(&1, 1)))

        {entries, cache} =
          Enum.map_reduce(found, cache, fn {env_id, id, listeners}, cache ->
            {owners, cache} = owners(ctx, id, listeners, cache, now)
            {{env_id, ports(listeners, owners)}, cache}
          end)

        report =
          entries
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Map.new(fn {env_id, lists} -> {env_id, finish(Enum.concat(lists))} end)

        {report, cache}

      {:error, reason} ->
        {:error, "couldn't list containers for ports: #{inspect(reason)}"}
    end
  end

  defp devcontainer?(%{
         "State" => "running",
         "Labels" => %{"foreman.devcontainer" => "true"} = labels
       }) do
    match?(
      {:ok, _},
      ForemanProtocol.Schema.cast(%{"id" => labels["foreman.env_id"]},
        id: {:uuid, required: true}
      )
    )
  end

  defp devcontainer?(_container), do: false

  # Reachable listening sockets in the container's network namespace.
  defp listeners(ctx, id) do
    proc = ctx.config.proc

    with true <- is_binary(id) and Regex.match?(~r/\A[0-9a-f]{12,64}\z/, id),
         {:ok, %{"State" => %{"Pid" => pid}}} when is_integer(pid) and pid > 0 <-
           ctx.docker.inspect_container(id),
         {:ok, tcp} <- File.read(Path.join([proc, Integer.to_string(pid), "net", "tcp"])) do
      # A kernel without IPv6 has no tcp6.
      tcp6 =
        case File.read(Path.join([proc, Integer.to_string(pid), "net", "tcp6"])) do
          {:ok, text} -> text
          {:error, _} -> ""
        end

      {:ok, (parse(tcp) ++ parse(tcp6)) |> Enum.filter(&reachable?(&1.address))}
    else
      _ -> :error
    end
  end

  defp ports(listeners, owners) do
    Enum.map(listeners, &{&1.port, Map.get(owners, &1.inode)})
  end

  # One entry per port, named after whichever of its sockets has a name.
  defp finish(ports) do
    ports
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.take(@max_ports)
    |> Enum.map(fn {port, names} ->
      case Enum.find(names, & &1) do
        nil -> %{port: port}
        name -> %{port: port, process: name}
      end
    end)
  end

  # Names for the container's listening sockets, from the cache while the
  # set of sockets is the same and the names are recent: a busy container
  # has thousands of fds.
  defp owners(_ctx, _id, [], cache, _now), do: {%{}, cache}

  defp owners(ctx, id, listeners, cache, now) do
    inodes = MapSet.new(listeners, & &1.inode)

    case cache do
      %{^id => {^inodes, owners, at}} when now - at < @names_ttl -> {owners, cache}
      _ -> look_up_owners(ctx, id, inodes, cache, now)
    end
  end

  # Not cached when Docker didn't answer, so the next check asks again. A
  # lookup that names nothing is, so it isn't repeated every few seconds.
  defp look_up_owners(ctx, id, inodes, cache, now) do
    case ctx.docker.top(id) do
      {:ok, pids} ->
        owners = owners(ctx.config.proc, pids, inodes)
        {owners, Map.put(cache, id, {inodes, owners, now})}

      {:error, reason} ->
        Logger.debug("couldn't list the processes in #{id}: #{inspect(reason)}")
        {%{}, cache}
    end
  end

  @doc """
  The listening sockets in a `/proc/net/tcp` or `tcp6` file, as
  `%{address: ip_tuple, port: port, inode: inode}`. Addresses are 32-bit
  words in the host's byte order, little-endian on every box Foreman
  supports; the port is big-endian.
  """
  @spec parse(String.t()) :: [map()]
  def parse(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [_sl, local, _remote, @listen, _, _, _, _, _, inode | _] <- String.split(line),
           [addr, port] <- String.split(local, ":"),
           {:ok, address} <- address(addr),
           {port, ""} when port in 1..65_535 <- Integer.parse(port, 16),
           {inode, ""} <- Integer.parse(inode) do
        [%{address: address, port: port, inode: inode}]
      else
        _ -> []
      end
    end)
  end

  defp address(hex) when byte_size(hex) in [8, 32] do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} ->
        words = for <<word::little-32 <- bytes>>, do: word

        case words do
          [a] ->
            {:ok, {a >>> 24 &&& 255, a >>> 16 &&& 255, a >>> 8 &&& 255, a &&& 255}}

          words ->
            {:ok, words |> Enum.flat_map(&[&1 >>> 16, &1 &&& 0xFFFF]) |> List.to_tuple()}
        end

      :error ->
        :error
    end
  end

  defp address(_hex), do: :error

  @doc "Whether tailscaled's connections from the tailnet reach a listener on this address."
  def reachable?({0, 0, 0, 0}), do: true
  def reachable?({127, 0, 0, 1}), do: true
  def reachable?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def reachable?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def reachable?({0, 0, 0, 0, 0, 0xFFFF, 0, 0}), do: true
  def reachable?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}), do: true
  def reachable?(_address), do: false

  @doc """
  Names for the `wanted` socket inodes, from the given host pids' fds. A
  socket held by several processes (forked workers) takes the lowest
  pid's name. Processes the agent can't read, or that are gone, are
  skipped. Stops once every wanted socket has a name, or before a process
  whose fds would take it past `budget`. The environment controls its
  process names, so they're cleaned and capped.
  """
  @spec owners(String.t(), [pos_integer()], MapSet.t(integer()), non_neg_integer()) ::
          %{integer() => String.t()}
  def owners(proc, pids, wanted, budget \\ @fd_budget) do
    pids
    |> Enum.sort()
    |> Enum.reduce_while({%{}, budget}, fn pid, {acc, left} ->
      dir = Path.join(proc, Integer.to_string(pid))
      fd_dir = Path.join(dir, "fd")

      case File.ls(fd_dir) do
        {:ok, fds} when length(fds) > left ->
          {:halt, {acc, left}}

        {:ok, fds} ->
          acc = name_sockets(acc, dir, socket_inodes(fd_dir, fds), wanted)

          if map_size(acc) == MapSet.size(wanted),
            do: {:halt, {acc, 0}},
            else: {:cont, {acc, left - length(fds)}}

        {:error, _} ->
          {:cont, {acc, left}}
      end
    end)
    |> elem(0)
  end

  defp name_sockets(acc, dir, inodes, wanted) do
    with [_ | _] = inodes <-
           Enum.filter(inodes, &(MapSet.member?(wanted, &1) and not Map.has_key?(acc, &1))),
         {:ok, comm} <- File.read(Path.join(dir, "comm")),
         name when name != "" <- clean(comm) do
      Enum.reduce(inodes, acc, &Map.put(&2, &1, name))
    else
      _ -> acc
    end
  end

  defp socket_inodes(dir, fds) do
    Enum.flat_map(fds, fn fd ->
      with {:ok, "socket:[" <> rest} <- File.read_link(Path.join(dir, fd)),
           {inode, "]"} <- Integer.parse(rest) do
        [inode]
      else
        _ -> []
      end
    end)
  end

  defp clean(name) do
    name
    |> String.replace_invalid()
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.trim()
    |> truncate(@max_name)
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s

  defp truncate(s, max) do
    s
    |> String.codepoints()
    |> Enum.reduce_while("", fn c, acc ->
      if byte_size(acc) + byte_size(c) <= max, do: {:cont, acc <> c}, else: {:halt, acc}
    end)
  end
end
