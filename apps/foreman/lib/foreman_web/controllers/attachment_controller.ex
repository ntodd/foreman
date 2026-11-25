defmodule ForemanWeb.AttachmentController do
  use ForemanWeb, :controller

  alias Foreman.Attachments

  @scope "attachments:create"

  def create(conn, %{"id" => env_id}) do
    with :ok <- allowed(conn),
         {:ok, upload} <- Attachments.start(conn.assigns.api_principal, env_id, conn.body_params) do
      conn |> put_status(:created) |> json(upload)
    else
      error -> refuse(conn, error)
    end
  end

  def append(conn, %{"id" => env_id, "attachment_id" => upload_id}) do
    with :ok <- allowed(conn),
         {:ok, progress} <-
           Attachments.append(conn.assigns.api_principal, env_id, upload_id, conn.body_params) do
      json(conn, progress)
    else
      error -> refuse(conn, error)
    end
  end

  # The connection's scope first, so one without it learns nothing about
  # what it named.
  defp allowed(conn) do
    if @scope in conn.assigns.api_principal.scopes,
      do: :ok,
      else: {:error, :insufficient_scope, "This connection lacks permission to attach files."}
  end

  defp refuse(conn, {:error, code, message}) do
    status =
      case code do
        :insufficient_scope -> :forbidden
        :forbidden -> :forbidden
        :repository_access_unavailable -> :service_unavailable
        :resource_not_found -> :not_found
        :invalid_request -> :unprocessable_entity
        :too_many_attachments -> :too_many_requests
        # GitHub's refusal, or its outage: nothing the request got wrong.
        :attachment_upload_failed -> :bad_gateway
        _ -> :conflict
      end

    conn |> put_status(status) |> json(%{code: code, message: message})
  end
end
