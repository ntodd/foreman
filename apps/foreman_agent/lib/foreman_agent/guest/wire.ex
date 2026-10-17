defmodule ForemanAgent.Guest.Wire do
  @moduledoc """
  How the host agent and the guest runner inside an environment's VM talk.

  The host hands the guest one request as a file (`request/2`): the
  command type and payload, secrets included, so nothing sensitive goes
  on a command line. The guest answers on stdout, one event per line:

      \\x1eFM {"log":"stdout","data":"<base64>"}
      \\x1eFM {"ok":{...}}            the operation's result
      \\x1eFM {"error":"..."}         or its error

  Anything else on stdout (the release's own boot output, say) is noise:
  the host logs it at most, and never takes a result from it. The guest
  is the environment's own VM, so what it says is untrusted input to the
  host, and is decoded as data only.
  """

  alias ForemanProtocol.{Command, Schema}

  @marker "\x1eFM "

  @type event ::
          {:log, String.t(), binary()}
          | {:result, {:ok, map()} | {:error, String.t()}}
          | {:noise, String.t()}

  @doc """
  The request file: the command as the protocol puts it on the wire. The
  guest validates it again with `ForemanProtocol.Command.new/2`, as the
  host did, rather than trusting a decoded term (and a fresh guest node
  hasn't loaded the modules whose atoms a term would need).
  """
  @spec request(String.t(), map()) :: binary()
  def request(type, payload) when is_binary(type) and is_map(payload) do
    JSON.encode!(%{"type" => type, "payload" => Schema.dump(payload, Command.spec(type))})
  end

  @spec decode_request(binary()) :: {:ok, {String.t(), map()}} | {:error, :invalid_request}
  def decode_request(binary) do
    with {:ok, %{"type" => type, "payload" => payload}} when is_binary(type) <-
           JSON.decode(binary),
         {:ok, %Command{payload: payload}} <- Command.new(type, payload) do
      {:ok, {type, payload}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  @spec log(String.t(), binary()) :: binary()
  def log(stream, data), do: line(%{"log" => stream, "data" => Base.encode64(data)})

  @spec result({:ok, map()} | {:error, String.t()}) :: binary()
  def result({:ok, map}) when is_map(map), do: line(%{"ok" => map})
  def result({:error, message}) when is_binary(message), do: line(%{"error" => message})

  defp line(map), do: @marker <> JSON.encode!(map) <> "\n"

  @doc "A decoder for the guest's stdout, fed one chunk at a time."
  def decoder, do: ""

  @spec feed(binary(), binary()) :: {[event()], binary()}
  def feed(buffer, chunk) do
    lines = String.split(buffer <> chunk, "\n")
    {complete, [rest]} = Enum.split(lines, -1)
    {Enum.map(complete, &decode_line/1), rest}
  end

  defp decode_line(@marker <> json = line) do
    case JSON.decode(json) do
      {:ok, %{"log" => stream, "data" => data}} when is_binary(stream) and is_binary(data) ->
        case Base.decode64(data) do
          {:ok, bytes} -> {:log, stream, bytes}
          :error -> {:noise, line}
        end

      {:ok, %{"ok" => result}} when is_map(result) ->
        {:result, {:ok, result}}

      {:ok, %{"error" => message}} when is_binary(message) ->
        {:result, {:error, message}}

      _ ->
        {:noise, line}
    end
  end

  defp decode_line(line), do: {:noise, line}
end
