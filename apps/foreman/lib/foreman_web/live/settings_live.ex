defmodule ForemanWeb.SettingsLive do
  @moduledoc "Your defaults: git identity and dotfiles. Repos can override them."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Environments}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:form, to_form(Accounts.change_preferences(user)))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_preferences(socket.assigns.current_scope.user, params)
    {:noreply, assign(socket, :form, to_form(%{changeset | action: :validate}))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_preferences(socket.assigns.current_scope, params) do
      {:ok, user} ->
        # Git identity lives in /run/foreman/gitconfig, so it applies without a restart.
        Environments.push_secrets(user_id: user.id)

        {:noreply,
         socket
         |> assign(:current_scope, Foreman.Scope.for_user(user))
         |> assign(:form, to_form(Accounts.change_preferences(user)))
         |> put_flash(
           :info,
           "Saved. Git identity applies to running environments now; dotfiles on their next rebuild."
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="narrow"
    >
      <:breadcrumb>Settings</:breadcrumb>

      <.header>
        Settings
        <:subtitle>
          Defaults for every environment you create. Each repo's page can override them.
        </:subtitle>
      </.header>

      <.form for={@form} id="preferences" phx-change="validate" phx-submit="save" class="space-y-6">
        <.panel title="Git identity">
          <:subtitle>
            Written to /run/foreman/gitconfig, which every process in the environment reads.
          </:subtitle>
          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:git_name]} label="Name" placeholder={@current_scope.user.name} />
            <.input field={@form[:git_email]} label="Email" placeholder="you@example.com" />
          </div>
        </.panel>

        <.panel title="Dotfiles">
          <:subtitle>
            A public git repo the devcontainer CLI clones and installs when an environment is built.
          </:subtitle>
          <div class="space-y-4">
            <.input
              field={@form[:dotfiles_repository]}
              label="Repository"
              placeholder="https://github.com/you/dotfiles.git"
            />
            <.input
              field={@form[:dotfiles_install_command]}
              label="Install command"
              placeholder="Defaults to install.sh, bootstrap.sh or setup.sh"
            />
          </div>
        </.panel>

        <div class="flex justify-end">
          <.button type="submit" variant="primary">Save</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
