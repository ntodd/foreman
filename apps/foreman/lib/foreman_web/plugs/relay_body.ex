defmodule ForemanWeb.Plugs.RelayBody do
  @moduledoc """
  Reads the body of a request a box relays, once, and keeps its SHA-256:
  `ForemanWeb.Plugs.RelayAuth` checks that against the box's signature,
  and `ForemanWeb.Plugs.RequestParsers` decodes the same bytes.
  """
  @digest :foreman_relay_body_sha256

  @doc "The whole body, up to `limit` bytes, with its digest kept on the conn."
  @spec read(Plug.Conn.t(), pos_integer()) ::
          {:ok, binary(), Plug.Conn.t()} | {:too_large, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def read(conn, limit) do
    case Plug.Conn.read_body(conn, length: limit) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.put_private(conn, @digest, :crypto.hash(:sha256, body))}

      {:more, _partial, conn} ->
        {:too_large, conn}

      {:error, _reason} ->
        {:error, conn}
    end
  end

  @doc "The SHA-256 of the body `read/2` read, or `:error` when none was."
  def digest(conn) do
    case conn.private[@digest] do
      digest when is_binary(digest) -> {:ok, digest}
      nil -> :error
    end
  end
end
