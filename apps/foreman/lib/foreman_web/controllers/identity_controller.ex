defmodule ForemanWeb.IdentityController do
  use ForemanWeb, :controller

  def show(conn, _) do
    %{user: user, kind: kind, client_id: client_id} = conn.assigns.api_principal
    # A user goes by their GitHub login. A service account's login is
    # internal, so it goes by the name its administrator gave it.
    name = if kind == :service_account, do: user.name, else: user.login

    conn
    |> json(
      Map.merge(
        %{id: user.id, kind: kind, client_id: client_id, name: name},
        environment(conn.assigns.api_principal)
      )
    )
  end

  # An environment's own connection (a box relays it) says which
  # environment it is, so a client inside one knows what it can reach.
  defp environment(%{environment_id: nil}), do: %{}

  # Read by id alone: the connection was made for this environment, and a
  # repository check that can't reach GitHub mustn't fail "who am I".
  defp environment(%{environment_id: id}) do
    case Foreman.Repo.get(Foreman.Environments.Environment, id) do
      %{slug: slug, destroyed_at: nil} -> %{environment: %{id: id, name: slug}}
      _ -> %{environment: %{id: id}}
    end
  end
end
