defmodule ForemanWeb.SecretsLive do
  @moduledoc "Your own secrets: for all your environments, or only some repos."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.Repos

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Secrets")
     |> assign(:repos, Repos.list_repos(with_devcontainer: true))}
  end

  @impl true
  def handle_info({event, name}, socket) when event in [:secret_saved, :secret_deleted] do
    verb = if event == :secret_saved, do: "Saved", else: "Deleted"

    {:noreply,
     put_flash(
       socket,
       :info,
       "#{verb} #{name}. Running environments have it now; restart them to apply it to running processes."
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="narrow"
    >
      <:breadcrumb>Secrets</:breadcrumb>

      <.header>
        Your secrets
        <:subtitle>
          Loaded in your environments' shells and available to their compose files as ${"{NAME}"}. Values are encrypted and write-only.
        </:subtitle>
      </.header>

      <.callout kind="info" icon="hero-arrows-up-down-mini">
        Precedence, lowest to highest: owner, repo, yours, then the environment's own. Yours override the repo's; an environment's override yours.
      </.callout>

      <.live_component
        module={ForemanWeb.SecretsComponent}
        id="user-secrets"
        title="Secrets"
        scope_name="user"
        subject={@current_scope.user}
        current_scope={@current_scope}
        repos={@repos}
      />
    </Layouts.app>
    """
  end
end
