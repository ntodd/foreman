defmodule ForemanWeb.OAuthController do
  @moduledoc "Device authorization, credential exchanges and revocation."
  use ForemanWeb, :controller

  alias Foreman.{OAuth, RateLimit, Repo}
  alias Foreman.OAuth.{Client, DeviceFlow, ServiceAccounts}

  plug :credential_response
  plug :require_form

  def device(conn, _) do
    params = conn.body_params

    with {:allow, _} <-
           RateLimit.hit("oauth-device:#{ForemanWeb.ClientIP.from_conn(conn)}", 60_000, 30),
         {:ok, client} <- public_client(conn, params),
         {:ok, body} <- DeviceFlow.start(client, params["scope"]) do
      json(conn, body)
    else
      {:deny, _} -> conn |> put_status(429) |> json(%{error: "temporarily_unavailable"})
      {:error, reason} -> error(conn, reason)
    end
  end

  def token(conn, _) do
    params = conn.body_params

    result =
      case params["grant_type"] do
        "urn:ietf:params:oauth:grant-type:device_code" ->
          with {:ok, client} <- public_client(conn, params),
               do: DeviceFlow.poll(client, params["device_code"])

        "refresh_token" ->
          with {:ok, client} <- public_client(conn, params),
               do: OAuth.refresh(client, params["refresh_token"], params["scope"])

        "client_credentials" ->
          basic_client(conn, params, &ServiceAccounts.issue(&1, params["scope"]))

        nil ->
          {:error, :invalid_request}

        _ ->
          {:error, :unsupported_grant_type}
      end

    case result do
      {:ok, body} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def revoke(conn, _) do
    params = conn.body_params

    result =
      if get_req_header(conn, "authorization") == [] do
        with {:ok, client} <- public_client(conn, params),
             do: OAuth.revoke(client, params["token"])
      else
        basic_client(conn, params, &OAuth.revoke(&1, params["token"]))
      end

    case result do
      {:ok, :revoked} -> send_resp(conn, 200, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  defp public_client(conn, params) do
    with [] <- get_req_header(conn, "authorization"),
         nil <- params["client_secret"],
         id when is_binary(id) <- params["client_id"],
         %Client{kind: "public", disabled_at: nil} = client <- Repo.get(Client, id) do
      {:ok, client}
    else
      _ -> {:error, :invalid_client}
    end
  end

  defp basic_client(conn, params, action) do
    with false <- Map.has_key?(params, "client_secret") or Map.has_key?(params, "client_id"),
         [_] <- get_req_header(conn, "authorization"),
         {id, secret} <- Plug.BasicAuth.parse_basic_auth(conn) do
      ServiceAccounts.with_credentials(id, secret, action)
    else
      _ -> {:error, :invalid_client}
    end
  end

  defp error(conn, :invalid_client) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Foreman"))
    |> put_status(401)
    |> json(%{error: :invalid_client})
  end

  defp error(conn, reason), do: conn |> put_status(400) |> json(%{error: reason})

  defp credential_response(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

  defp require_form(conn, _) do
    case get_req_header(conn, "content-type") do
      ["application/x-www-form-urlencoded" <> _] -> conn
      _ -> conn |> error(:invalid_request) |> halt()
    end
  end
end
