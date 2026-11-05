defmodule ForemanWeb.ObanResolver do
  @moduledoc """
  Oban Web for admins only. The router requires an admin for the page and
  for every LiveView mount (see the router's `oban_dashboard`).
  """
  @behaviour Oban.Web.Resolver

  # Oban Web puts this in the page's LiveView session, which is signed but
  # not encrypted: the id and role, never the user with its GitHub tokens.
  @impl true
  def resolve_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{id: id, login: login, role: role}} -> %{id: id, login: login, role: role}
      _ -> nil
    end
  end

  @impl true
  def resolve_access(%{role: "admin"}), do: :all
  def resolve_access(_user), do: {:forbidden, "/"}
end
