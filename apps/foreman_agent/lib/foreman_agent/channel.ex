defmodule ForemanAgent.Channel do
  @moduledoc """
  The channel between the agent on a box (the host) and the agent in an
  environment's VM (the guest).

  It runs over Cloud Hypervisor's hybrid vsock: the host connects to the
  VM's vsock unix socket, writes `CONNECT <port>\\n` and reads `OK ...\\n`,
  and the rest of the stream reaches whatever listens on that port in the
  guest. In the guest, `socat` joins vsock port 1024 to the guest agent's
  unix socket. Each frame is a JSON object with a four-byte length,
  at most 4 MiB, and a type in `"t"`.

  Host to guest:

    * `hello`: `now` (the host's Unix time in milliseconds) and `config`
      (the clone hosts the box allows). Sent first on every connection.
    * `cmd`: a protocol command (`ForemanProtocol.Command.to_wire/1`), with
      the op id the control plane gave it, and `now`.
    * `cancel`: `op_id` of a command to cancel.
    * `ack`: `seq` of an event the host has taken.
    * `query`: `id` and `q` (`inventory` or `ports`).

  Guest to host:

    * `hello`: `agent_version`.
    * `event`: a protocol event (`op.accepted`, `op.log`, `op.result`) and
      `seq`, which the host acknowledges when it's set.
    * `reply`: `id`, `ok` and `result`, answering a query.

  The guest is the environment's, and anything in the environment can
  take it over, so the host treats every frame it reads as hostile: see
  `ForemanAgent.VM.Link`.
  """

  @port 1024
  @max_frame 4 * 1024 * 1024

  @doc "The vsock port the guest agent listens on."
  def port, do: @port

  @doc "The largest frame either side accepts, in bytes."
  def max_frame, do: @max_frame

  @doc "Socket options for a connection carrying frames, in passive mode."
  def frame_opts, do: [packet: 4, packet_size: @max_frame]

  @spec encode(map()) :: iodata()
  def encode(frame) when is_map(frame), do: JSON.encode_to_iodata!(frame)

  @doc "Decodes a frame: a JSON object with a string type."
  @spec decode(binary()) :: {:ok, map()} | {:error, :malformed}
  def decode(data) when is_binary(data) do
    case JSON.decode(data) do
      {:ok, %{"t" => type} = frame} when is_binary(type) -> {:ok, frame}
      _ -> {:error, :malformed}
    end
  end

  @doc "Sends a frame on a socket set up with `frame_opts/0`."
  @spec send_frame(:gen_tcp.socket(), map()) :: :ok | {:error, term()}
  def send_frame(socket, frame), do: :gen_tcp.send(socket, encode(frame))

  @doc "The current time as the host sends it, in Unix milliseconds."
  def now, do: System.os_time(:millisecond)
end
