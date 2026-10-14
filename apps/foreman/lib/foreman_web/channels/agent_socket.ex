defmodule ForemanWeb.AgentSocket do
  @moduledoc """
  The socket agents dial in on. Every connect must carry headers signed
  with the agent's enrolled ed25519 key (`ForemanProtocol.Auth`); stale
  clocks, unknown or revoked agents, bad signatures and replayed nonces
  are refused before a socket exists.
  """
  use Phoenix.Socket

  alias Foreman.Agents.NonceCache
  alias ForemanProtocol.Auth

  require Logger

  channel "agent:*", ForemanWeb.AgentChannel

  @impl true
  def connect(_params, socket, connect_info) do
    headers = Map.new(connect_info[:x_headers] || [], fn {k, v} -> {String.downcase(k), v} end)
    ip = peer_ip(connect_info)

    with {:allow, _} <- Foreman.RateLimit.hit("agent-connect:#{ip}", 60_000, 60),
         {:ok, %{agent_id: agent_id, nonce: nonce}} <-
           Auth.verify_connect_headers(headers, &Foreman.Boxes.public_key/1),
         :ok <- NonceCache.check(nonce) do
      {:ok, assign(socket, :box_id, agent_id)}
    else
      {:deny, _} ->
        Logger.warning("agent connects from #{ip} are rate limited")
        :error

      reason ->
        Logger.warning("refused an agent connect from #{ip}: #{inspect(reason)}")
        :error
    end
  end

  # Lets Foreman.Boxes.revoke/2 (and re-enrollment) drop the socket.
  @impl true
  def id(socket), do: "agent_socket:#{socket.assigns.box_id}"

  defp peer_ip(%{peer_data: %{address: address}}), do: address |> :inet.ntoa() |> to_string()
  defp peer_ip(_), do: "unknown"
end
