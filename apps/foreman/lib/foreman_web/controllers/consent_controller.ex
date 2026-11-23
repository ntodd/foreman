defmodule ForemanWeb.ConsentController do
  use ForemanWeb, :controller
  alias Foreman.{OAuth, RateLimit}
  alias Foreman.OAuth.DeviceFlow

  plug :private_page
  plug :limit_attempts when action in [:show, :decide]

  def show(conn, params) do
    code = params["user_code"]
    device = DeviceFlow.lookup(code)

    render(conn, :show,
      page_title: "Connect a device",
      device: device,
      user_code: code,
      invalid: code != nil and device == nil
    )
  end

  def decide(conn, %{"user_code" => code, "decision" => decision}) do
    result =
      DeviceFlow.decide(
        code,
        decision,
        conn.assigns.current_scope.user,
        get_session(conn, :session_token)
      )

    case result do
      {:ok, decision} ->
        render(conn, :result, page_title: "Device authorization", decision: decision)

      {:error, _} ->
        conn
        |> put_status(400)
        |> render(:show,
          page_title: "Connect a device",
          user_code: nil,
          device: nil,
          invalid: true
        )
    end
  end

  def decide(conn, _), do: decide(conn, %{"user_code" => nil, "decision" => nil})

  def connections(conn, _) do
    render(conn, :connections,
      page_title: "Connected apps",
      grants: OAuth.connections(conn.assigns.current_scope.user.id)
    )
  end

  def disconnect(conn, %{"id" => id}) do
    case OAuth.disconnect(conn.assigns.current_scope.user, id) do
      :ok -> redirect(conn, to: ~p"/settings/connections")
      :error -> send_resp(conn, 404, "Connection not found")
    end
  end

  defp limit_attempts(conn, _) do
    case RateLimit.hit("oauth-consent:#{conn.assigns.current_scope.user.id}", 60_000, 30) do
      {:allow, _} -> conn
      {:deny, _} -> conn |> send_resp(429, "Try again in a minute.") |> halt()
    end
  end

  defp private_page(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
end
