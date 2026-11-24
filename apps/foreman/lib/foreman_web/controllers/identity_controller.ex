defmodule ForemanWeb.IdentityController do
  use ForemanWeb, :controller

  def show(conn, _) do
    %{user: user, kind: kind, client_id: client_id} = conn.assigns.api_principal
    # A user goes by their GitHub login. A service account's login is
    # internal, so it goes by the name its administrator gave it.
    name = if kind == :service_account, do: user.name, else: user.login
    json(conn, %{id: user.id, kind: kind, client_id: client_id, name: name})
  end
end
