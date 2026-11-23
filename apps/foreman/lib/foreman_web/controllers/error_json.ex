defmodule ForemanWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  def render("503.json", %{reason: %Foreman.PublicAPI.Access.Unavailable{} = error}) do
    %{code: "repository_access_unavailable", message: Exception.message(error)}
  end

  def render("404.json", %{
        reason: %Phoenix.Router.NoRouteError{conn: %{path_info: ["api", "v1" | _]}}
      }) do
    %{code: "resource_not_found", message: "Resource not found."}
  end

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
