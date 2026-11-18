defmodule ForemanAgent.Channel do
  @moduledoc """
  The channel between the agent on a box (the host) and the agent in an
  environment's VM (the guest).

  It runs over Cloud Hypervisor's hybrid vsock: the host connects to the
  VM's vsock unix socket, writes `CONNECT <port>\\n` and reads `OK ...\\n`,
  and the rest of the stream reaches whatever listens on that port in the
  guest. In the guest, `socat` joins vsock port 1024 to the guest agent's
  unix socket. Each frame is a JSON object with a four-byte length and a
  type in `"t"`: at most 4 MiB from the host (a command can carry
  secrets files) and 1 MiB from the guest.

  Host to guest:

    * `hello`: `now` (the host's Unix time in milliseconds) and `config`
      (the clone hosts the box allows). Sent first on every connection.
    * `cmd`: a protocol command (`ForemanProtocol.Command.to_wire/1`), with
      the op id the control plane gave it, and `now`.
    * `cancel`: `op_id` of a command to cancel.
    * `ack`: `seq` of an event the host has taken.
    * `query`: `id`, `q` (`inventory`, `ports` or `reclaim`) and, for
      `reclaim`, `args`: `keep_mb`, the MiB of page cache to keep (see
      `ForemanAgent.Guest.Reclaim`).

  Guest to host:

    * `hello`: `agent_version`, and `instance`: an id the guest agent's
      `ForemanAgent.Ops` picks when it starts. A new one means the guest
      has forgotten the commands it ran.
    * `event`: a protocol event (`op.accepted`, `op.log`, `op.result`) and
      `seq`, which the host acknowledges when it's set.
    * `reply`: `id`, `ok` and `result`, answering a query.

  The guest is the environment's, and anything in the environment can
  take it over, so the host treats every frame it reads as hostile: see
  `ForemanAgent.VM.Link`.
  """

  @port 1024
  @max_to_guest 4 * 1024 * 1024
  @max_to_host 1024 * 1024
  # What decoding one guest frame may cost. The guest is hostile and the
  # decode runs in the host agent's BEAM, not the VM's cgroup, so this is
  # held to what a legitimate frame needs. A big integer, a deep tree or a
  # map of many keys is killed by the heap in a few milliseconds; the
  # largest honest frames (a 1 MiB string, an environment's inventory or
  # ports) decode in a few ms, well under the heap and the timeout.
  @decode_heap 2 * 1024 * 1024
  @decode_timeout 200

  @doc "The vsock port the guest agent listens on."
  def port, do: @port

  @doc "The largest frame, in bytes, `:to_guest` or `:to_host`."
  def max_frame(:to_guest), do: @max_to_guest
  def max_frame(:to_host), do: @max_to_host

  @doc """
  Socket options for a connection carrying frames, in passive mode, for
  the end that reads them: `:host` or `:guest`.
  """
  def frame_opts(:host), do: [packet: 4, packet_size: @max_to_host]
  def frame_opts(:guest), do: [packet: 4, packet_size: @max_to_guest]

  @spec encode(map()) :: iodata()
  def encode(frame) when is_map(frame), do: JSON.encode_to_iodata!(frame)

  @doc """
  Decodes a frame: a JSON object with a string type.

  A frame can be built to be costly to decode (deep nesting, numbers with
  a million digits), so it's decoded in a process of its own with a heap
  of at most `:max_heap` bytes (default 2 MiB) and `:timeout`
  milliseconds (default 200). One that needs more is malformed.
  """
  @spec decode(binary(), keyword()) :: {:ok, map()} | {:error, :malformed}
  def decode(data, opts \\ []) when is_binary(data) do
    words = div(Keyword.get(opts, :max_heap, @decode_heap), :erlang.system_info(:wordsize))
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      Process.spawn(fn -> send(parent, {tag, parse(data)}) end, [
        :monitor,
        max_heap_size: %{size: words, kill: true, error_logger: false}
      ])

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, :malformed}
    after
      Keyword.get(opts, :timeout, @decode_timeout) ->
        Process.exit(pid, :kill)

        # Its result, if it sent one, comes before this.
        receive do
          {:DOWN, ^monitor, :process, _, _} -> :ok
        end

        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :malformed}
    end
  end

  defp parse(data) do
    case JSON.decode(data) do
      {:ok, %{"t" => type} = frame} when is_binary(type) -> {:ok, frame}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  @doc """
  Sends a frame on a socket set up with `frame_opts/1`, if it's at most
  `max` bytes encoded.
  """
  @spec send_frame(:gen_tcp.socket(), map(), pos_integer()) ::
          :ok | {:error, :too_large | term()}
  def send_frame(socket, frame, max) do
    data = encode(frame)

    if IO.iodata_length(data) > max,
      do: {:error, :too_large},
      else: :gen_tcp.send(socket, data)
  end

  @doc "The current time as the host sends it, in Unix milliseconds."
  def now, do: System.os_time(:millisecond)
end
