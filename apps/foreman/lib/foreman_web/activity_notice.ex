defmodule ForemanWeb.ActivityNotice do
  @moduledoc """
  Turns a `Foreman.Activity` event into the flash notice every page
  shows: the environment or box as the title, what happened, and a link
  to it. `ForemanWeb.UserAuth` puts it on the page.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: ForemanWeb.Endpoint,
    router: ForemanWeb.Router,
    statics: ForemanWeb.static_paths()

  alias Foreman.Activity
  alias ForemanWeb.ForemanComponents

  @max_error 160

  @doc "`{kind, message}` for put_flash, or nil if the event isn't one to show."
  def flash(%Activity{kind: :operation, action: "agent.update"} = e) do
    case e.status do
      "succeeded" -> {:info, notice(e, "Agent updated to #{e.version}")}
      "failed" -> {:error, notice(e, "Agent update to #{e.version} failed#{why(e)}")}
    end
  end

  def flash(%Activity{kind: :operation} = e) do
    case e.status do
      "succeeded" ->
        {:info, notice(e, done(e.action))}

      "failed" ->
        {:error, notice(e, "#{ForemanComponents.action_label(e.action)} failed#{why(e)}")}
    end
  end

  def flash(%Activity{kind: :box_joined} = e), do: {:info, notice(e, "Joined Foreman")}
  def flash(%Activity{kind: :box_online} = e), do: {:info, notice(e, "Back online")}
  def flash(%Activity{kind: :box_offline} = e), do: {:error, notice(e, "Went offline")}

  def flash(%Activity{kind: :box_reboot_required} = e), do: {:info, notice(e, "Needs a reboot")}

  defp done("create"), do: "Created and running"
  defp done("start"), do: "Started"
  defp done("stop"), do: "Stopped"
  defp done("rebuild"), do: "Rebuilt"
  defp done("pull_rebuild"), do: "Rebuilt with the latest"
  defp done("destroy"), do: "Destroyed"
  defp done(restart) when restart in ~w(restart_affected restart_all), do: "Restarted"

  defp why(%Activity{error: nil}), do: ""

  defp why(%Activity{error: error}) do
    error = error |> String.trim() |> String.replace(~r/\s+/, " ")

    if String.length(error) > @max_error,
      do: ": " <> String.slice(error, 0, @max_error) <> "…",
      else: ": " <> error
  end

  defp notice(e, text), do: %{title: e.subject, text: text, path: path(e)}

  # A destroyed environment's page is gone.
  defp path(%Activity{action: "destroy", status: "succeeded"}), do: nil
  defp path(%Activity{env_id: id}) when is_binary(id), do: ~p"/environments/#{id}"
  defp path(%Activity{box_id: id}) when is_binary(id), do: ~p"/boxes/#{id}"
end
