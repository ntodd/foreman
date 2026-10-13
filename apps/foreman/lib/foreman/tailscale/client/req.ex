defmodule Foreman.Tailscale.Client.Req do
  @moduledoc "`Foreman.Tailscale.Client` over the Tailscale API with Req."
  @behaviour Foreman.Tailscale.Client

  @api "https://api.tailscale.com"

  @impl true
  def create_auth_key(creds, opts) do
    body = %{
      capabilities: %{
        devices: %{
          create: %{reusable: false, ephemeral: false, preauthorized: true, tags: opts.tags}
        }
      },
      expirySeconds: opts.expiry_seconds,
      description: String.slice(opts.description, 0, 50)
    }

    with {:ok, req} <- authed(creds) do
      case Req.post(req, url: "/api/v2/tailnet/#{tailnet(creds)}/keys", json: body) do
        {:ok, %{status: 200, body: %{"key" => key, "id" => id}}} -> {:ok, %{key: key, id: id}}
        other -> unexpected(other)
      end
    end
  end

  @impl true
  def list_devices(creds) do
    with {:ok, req} <- authed(creds) do
      case Req.get(req, url: "/api/v2/tailnet/#{tailnet(creds)}/devices") do
        {:ok, %{status: 200, body: %{"devices" => devices}}} -> {:ok, devices}
        other -> unexpected(other)
      end
    end
  end

  @impl true
  def delete_device(creds, device_id) do
    with {:ok, req} <- authed(creds) do
      case Req.delete(req, url: "/api/v2/device/#{URI.encode_www_form(device_id)}") do
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        other -> unexpected(other)
      end
    end
  end

  defp tailnet(creds), do: URI.encode_www_form(creds[:tailnet] || "-")

  # OAuth access tokens last an hour; cache one per client until near expiry.
  defp authed(creds) do
    key = {__MODULE__, creds.client_id}

    case :persistent_term.get(key, nil) do
      {token, expires} ->
        if System.monotonic_time(:second) < expires,
          do: {:ok, req(token)},
          else: fetch_token(creds, key)

      nil ->
        fetch_token(creds, key)
    end
  end

  defp fetch_token(creds, key) do
    case Req.post(base(),
           url: "/api/v2/oauth/token",
           form: [
             client_id: creds.client_id,
             client_secret: creds.client_secret,
             grant_type: "client_credentials"
           ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        expires = System.monotonic_time(:second) + (body["expires_in"] || 3600) - 120
        :persistent_term.put(key, {token, expires})
        {:ok, req(token)}

      other ->
        unexpected(other)
    end
  end

  defp base do
    Req.new(base_url: @api, retry: :transient, max_retries: 2)
    |> Req.merge(Application.get_env(:foreman, :tailscale_req_options, []))
  end

  defp req(token), do: Req.merge(base(), auth: {:bearer, token})

  defp unexpected({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http, status, if(is_map(body), do: body["message"])}}
  end

  defp unexpected({:error, exception}), do: {:error, exception}
end
