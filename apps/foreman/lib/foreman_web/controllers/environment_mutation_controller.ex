defmodule ForemanWeb.EnvironmentMutationController do
  use ForemanWeb, :controller

  alias Foreman.PublicAPI.Mutations

  plug ForemanWeb.Plugs.ApiAuth

  def create(conn, _params) do
    respond(
      conn,
      Mutations.create(conn.assigns.api_principal, request_key(conn), conn.body_params)
    )
  end

  def operate(conn, _params) do
    respond(
      conn,
      Mutations.operate(
        conn.assigns.api_principal,
        conn.path_params["id"],
        request_key(conn),
        conn.body_params
      )
    )
  end

  defp request_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] -> key
      _ -> nil
    end
  end

  defp respond(conn, {:ok, env, nil}), do: json(conn, %{environment_id: env})

  defp respond(conn, {:ok, env, op}) do
    conn
    |> put_resp_header("location", "/api/v1/operations/#{op}")
    |> put_status(:accepted)
    |> json(%{environment_id: env, operation_id: op})
  end

  defp respond(conn, {:error, code, message}) do
    status =
      case code do
        :resource_not_found -> :not_found
        :invalid_request -> :unprocessable_entity
        :insufficient_scope -> :forbidden
        :original_environment_gone -> :gone
        _ -> :conflict
      end

    conn |> put_status(status) |> json(%{code: code, message: message})
  end
end
