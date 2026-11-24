defmodule ForemanWeb.SecretMutationController do
  use ForemanWeb, :controller

  alias Foreman.PublicAPI.Secrets

  @scope "secrets:write"

  def update(conn, %{"scope" => scope, "subject" => raw}) do
    principal = conn.assigns.api_principal

    result =
      with true <- @scope in principal.scopes || {:error, :scope},
           {:ok, scope, subject} <- Secrets.subject(principal, scope, raw) do
        Secrets.change(principal, scope, subject, conn.body_params)
      end

    respond(conn, result)
  end

  defp respond(conn, {:ok, body}), do: json(conn, body)

  defp respond(conn, {:error, :scope}),
    do:
      error(
        conn,
        403,
        "insufficient_scope",
        "This connection lacks permission to change secrets."
      )

  defp respond(conn, {:error, :role}),
    do:
      error(
        conn,
        403,
        "forbidden",
        "Secrets are managed through a personal connection, and a repository's or an owner's take an admin."
      )

  defp respond(conn, {:error, :missing}),
    do: error(conn, 404, "resource_not_found", "Resource not found.")

  defp respond(conn, {:error, :resource_not_found, message}),
    do: error(conn, 404, "resource_not_found", message)

  defp respond(conn, {:error, :invalid_request, message}),
    do: error(conn, 422, "invalid_request", message)

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{code: code, message: message})
end
