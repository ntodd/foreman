defmodule ForemanWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  def render("503.json", %{reason: %Foreman.PublicAPI.Access.Unavailable{} = error}) do
    %{code: "repository_access_unavailable", message: Exception.message(error)}
  end

  def render(template, assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    case assigns do
      %{conn: %{path_info: path}} ->
        if ForemanWeb.Plugs.OAuthTransport.policy(path) == :resource do
          %{code: resource_error(template), message: message}
        else
          %{errors: %{detail: message}}
        end

      _ ->
        %{errors: %{detail: message}}
    end
  end

  defp resource_error("404.json"), do: "resource_not_found"
  defp resource_error("406.json"), do: "not_acceptable"
  defp resource_error("4" <> _), do: "invalid_request"
  defp resource_error(_), do: "internal_error"
end
