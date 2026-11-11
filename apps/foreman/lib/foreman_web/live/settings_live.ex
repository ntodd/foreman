defmodule ForemanWeb.SettingsLive do
  @moduledoc """
  Your defaults: git identity and dotfiles, which repos can override, and
  the devcontainer features you add to all your environments, which repos
  can turn off.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Environments}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:form, to_form(Accounts.change_preferences(user)))
     |> assign(:features_form, features_form(user))}
  end

  defp features_form(user, json \\ nil, errors \\ []) do
    json = json || features_json(user.devcontainer_features)
    to_form(%{"json" => json}, as: :features, errors: Enum.map(errors, &{:json, {&1, []}}))
  end

  defp features_json(features) when features == %{} or is_nil(features), do: ""
  defp features_json(features), do: Jason.encode!(features, pretty: true)

  # Written the way devcontainer.json's "features" object is, so a block
  # can be pasted from one. An empty box means none.
  defp decode_features(json) do
    case String.trim(json) do
      "" ->
        {:ok, %{}}

      json ->
        case JSON.decode(json) do
          {:ok, features} -> {:ok, features}
          {:error, _} -> {:error, "isn't valid JSON"}
        end
    end
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

  def handle_event("save_features", %{"features" => %{"json" => json}}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, features} <- decode_features(json),
         {:ok, user} <- Accounts.update_features(scope, features) do
      {:noreply,
       socket
       |> assign(:current_scope, Foreman.Scope.for_user(user))
       |> assign(:features_form, features_form(user))
       |> put_flash(:info, "Saved. Features change on each environment's next rebuild.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        errors = for {:devcontainer_features, {msg, _}} <- changeset.errors, do: msg
        {:noreply, assign(socket, :features_form, features_form(scope.user, json, errors))}

      {:error, message} ->
        {:noreply, assign(socket, :features_form, features_form(scope.user, json, [message]))}
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
            <.input
              field={@form[:dotfiles_target_path]}
              label="Clone to"
              placeholder="~/dotfiles"
            />
          </div>
        </.panel>

        <div class="flex justify-end">
          <.button type="submit" variant="primary">Save</.button>
        </div>
      </.form>

      <.form for={@features_form} id="features" phx-submit="save_features" class="mt-6">
        <.panel title="Devcontainer features">
          <:subtitle>
            Added to every environment you create, in any repo, as devcontainer.json's
            <code>features</code>
            object has them. Only your environments get them, and each repo's page can turn them off there. A feature runs code in your environments, so admins can see these.
          </:subtitle>
          <.input
            field={@features_form[:json]}
            type="textarea"
            label="Features"
            rows="8"
            class="input font-mono text-sm"
            placeholder={~s({\n  "ghcr.io/owner/features/name:1": {}\n})}
          />
          <p class="text-xs text-ink-3">
            A tag like <code>:1</code>
            isn't locked: each rebuild gets the newest version it points to. A feature the repo already has is skipped, and the repo's copy installs. Admins can see options too, so don't put secrets in them. Changes apply on the next rebuild.
          </p>
        </.panel>

        <div class="mt-6 flex justify-end">
          <.button type="submit" variant="primary">Save features</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
