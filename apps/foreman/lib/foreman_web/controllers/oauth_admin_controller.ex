defmodule ForemanWeb.OAuthAdminController do
  use ForemanWeb, :controller
  alias Foreman.OAuth.{Scopes, ServiceAccounts}

  def index(conn, _), do: page(conn)

  def register(conn, params) do
    result = ServiceAccounts.register(conn.assigns.current_scope, params["kind"], params)
    respond(conn, result)
  end

  def rotate(conn, %{"id" => id}),
    do: respond(conn, ServiceAccounts.rotate(conn.assigns.current_scope, id))

  def disable(conn, %{"id" => id}),
    do: respond(conn, ServiceAccounts.disable(conn.assigns.current_scope, id))

  defp respond(conn, {:ok, %{secret: secret, client: client}}),
    do: page(conn, {client.id, secret})

  defp respond(conn, {:ok, _}), do: redirect(conn, to: ~p"/admin/apps")

  defp respond(conn, {:error, :unauthorized}), do: forbidden(conn)

  defp respond(conn, {:error, reason}),
    do: page(conn |> put_status(422) |> put_flash(:error, "Could not save: #{reason}."))

  defp page(conn, credential \\ nil) do
    case ServiceAccounts.inventory(conn.assigns.current_scope) do
      {:ok, inventory} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> render(:index,
          page_title: "API clients",
          clients: inventory.clients,
          installations: Map.new(inventory.installations, &{&1.client_id, &1}),
          choices: inventory.choices,
          scopes: Scopes.service(),
          credential: credential
        )

      {:error, :unauthorized} ->
        forbidden(conn)
    end
  end

  defp forbidden(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:forbidden)
    |> text("Forbidden")
  end
end
