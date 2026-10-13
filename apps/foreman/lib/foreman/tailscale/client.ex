defmodule Foreman.Tailscale.Client do
  @moduledoc """
  The Tailscale API calls Foreman makes, authenticated with an OAuth
  client (scopes: `auth_keys` and `devices:core`).
  """

  @type creds :: %{client_id: String.t(), client_secret: String.t(), tailnet: String.t()}

  @callback create_auth_key(creds, %{
              tags: [String.t()],
              description: String.t(),
              expiry_seconds: pos_integer()
            }) ::
              {:ok, %{key: String.t(), id: String.t()}} | {:error, term()}
  @callback list_devices(creds) :: {:ok, [map()]} | {:error, term()}
  @callback delete_device(creds, device_id :: String.t()) :: :ok | {:error, term()}

  def impl, do: Application.get_env(:foreman, :tailscale_client, Foreman.Tailscale.Client.Req)
end
