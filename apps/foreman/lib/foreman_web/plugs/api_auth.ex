defmodule ForemanWeb.Plugs.ApiAuth do
  @moduledoc "Load a bearer principal for a public API request."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    with [authorization] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(authorization, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         {:ok, principal} <- Foreman.OAuth.authenticate(token) do
      assign(conn, :api_principal, principal)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="Foreman", error="invalid_token"))
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
          code: "invalid_token",
          message: "A valid access token is required."
        })
        |> halt()
    end
  end
end
