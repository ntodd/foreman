defmodule ForemanWeb.OAuthMetadataController do
  @moduledoc "Authorization server metadata at the configured public origin."
  use ForemanWeb, :controller

  def show(conn, _params) do
    issuer = Foreman.Config.base_url()

    json(conn, %{
      issuer: issuer,
      device_authorization_endpoint: issuer <> "/oauth/device/code",
      token_endpoint: issuer <> "/oauth/token",
      revocation_endpoint: issuer <> "/oauth/revoke",
      scopes_supported: Foreman.OAuth.Scopes.all(),
      grant_types_supported: [
        "urn:ietf:params:oauth:grant-type:device_code",
        "refresh_token",
        "client_credentials"
      ],
      response_types_supported: [],
      token_endpoint_auth_methods_supported: ["none", "client_secret_basic"],
      revocation_endpoint_auth_methods_supported: ["none", "client_secret_basic"]
    })
  end
end
