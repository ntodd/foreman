defmodule ForemanWeb.OAuthMetadataControllerTest do
  use ForemanWeb.ConnCase, async: true

  test "a headless client discovers Foreman's endpoints and individually grantable actions", %{
    conn: conn
  } do
    issuer = Foreman.Config.base_url()

    metadata =
      %{conn | host: "proxy.internal"}
      |> get("/.well-known/oauth-authorization-server")
      |> json_response(200)

    assert metadata["issuer"] == issuer
    assert metadata["device_authorization_endpoint"] == issuer <> "/oauth/device/code"
    assert metadata["token_endpoint"] == issuer <> "/oauth/token"
    assert metadata["revocation_endpoint"] == issuer <> "/oauth/revoke"
    assert metadata["response_types_supported"] == []

    assert Enum.sort(metadata["grant_types_supported"]) ==
             [
               "client_credentials",
               "refresh_token",
               "urn:ietf:params:oauth:grant-type:device_code"
             ]

    assert Enum.sort(metadata["token_endpoint_auth_methods_supported"]) ==
             ["client_secret_basic", "none"]

    assert Enum.sort(metadata["scopes_supported"]) ==
             ~w(boxes:list environments:create environments:destroy environments:list
                environments:read environments:start environments:stop logs:read operations:list
                operations:read repos:list)
  end
end
