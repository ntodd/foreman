defmodule ForemanWeb.IdentityController do
  use ForemanWeb, :controller

  def show(conn, _) do
    %{user: user, kind: kind, client_id: client_id} = conn.assigns.api_principal
    json(conn, %{id: user.id, kind: kind, client_id: client_id})
  end
end
