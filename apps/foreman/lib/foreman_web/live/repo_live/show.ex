defmodule ForemanWeb.RepoLive.Show do
  @moduledoc """
  One repo: its environments, your git identity and dotfiles overrides
  for it, and (admins) its token scope, Tailscale tags, default limits and
  repo-level secrets.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Environments, Repos, Scope}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    repo = Repos.get_repo!(id)
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:repo, repo)
     |> assign(:page_title, repo.full_name)
     |> assign(:settings_form, to_form(settings_params(repo), as: :settings))
     |> assign(
       :override_form,
       to_form(override_params(Accounts.get_repo_setting(user, repo)), as: :override)
     )
     |> assign(
       :environments,
       Environments.list_environments(socket.assigns.current_scope)
       |> Enum.filter(&(&1.repo_id == repo.id))
     )}
  end

  defp settings_params(repo) do
    %{
      "token_mode" => repo.token_mode,
      "extra_repos" => Enum.join(repo.extra_repos, ", "),
      "tailscale_tags" => Enum.join(repo.tailscale_tags, ", "),
      "cpu_limit" => repo.cpu_limit,
      "memory_limit_mb" => repo.memory_limit_mb,
      "default_branch" => repo.default_branch
    }
  end

  defp override_params(nil),
    do: %{
      "git_name" => "",
      "git_email" => "",
      "dotfiles_repository" => "",
      "dotfiles_install_command" => ""
    }

  defp override_params(s),
    do:
      Map.new(
        [:git_name, :git_email, :dotfiles_repository, :dotfiles_install_command],
        &{Atom.to_string(&1), Map.get(s, &1)}
      )

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Repos.update_repo_settings(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> assign(:repo, Repos.get_repo!(repo.id))
         |> assign(:settings_form, to_form(settings_params(repo), as: :settings))
         |> put_flash(
           :info,
           "Saved. Running environments get a token with the new scope when they next start, or within four hours. New limits apply when an environment is rebuilt."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :settings_form, to_form(%{changeset | action: :update}, as: :settings))}

      {:error, :unauthorized} ->
        {:noreply, socket}
    end
  end

  def handle_event("save_override", %{"override" => params}, socket) do
    case Accounts.put_repo_setting(socket.assigns.current_scope, socket.assigns.repo, params) do
      {:ok, setting} ->
        Environments.push_secrets(user_id: socket.assigns.current_scope.user.id)

        {:noreply,
         socket
         |> assign(:override_form, to_form(override_params(setting), as: :override))
         |> put_flash(
           :info,
           "Saved. Git identity applies right away; dotfiles on the next rebuild."
         )}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :override_form, to_form(%{changeset | action: :update}, as: :override))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb navigate={~p"/repos"}>Repos</:breadcrumb>
      <:breadcrumb>{@repo.full_name}</:breadcrumb>
      <:actions>
        <.button
          :if={@repo.devcontainer_path}
          navigate={~p"/environments/new?repo_id=#{@repo.id}"}
          variant="primary"
          size="sm"
          icon="hero-plus"
        >
          New environment
        </.button>
      </:actions>

      <.header>
        {@repo.full_name}
        <:subtitle>
          <span :if={@repo.devcontainer_path} class="font-mono">{@repo.devcontainer_path}</span>
          <span :if={is_nil(@repo.devcontainer_path)}>No devcontainer found.</span>
        </:subtitle>
      </.header>

      <.callout :if={@repo.devcontainer_error} kind="warning">{@repo.devcontainer_error}</.callout>

      <div class="grid items-start gap-6 lg:grid-cols-2">
        <.panel title="Environments">
          <ul :if={@environments != []} class="-m-5 divide-y divide-line">
            <li
              :for={env <- @environments}
              class="flex items-center justify-between gap-2 px-5 py-2.5"
            >
              <.link
                navigate={~p"/environments/#{env.id}"}
                class="font-mono text-sm font-medium text-ink hover:text-accent-ink"
              >{env.slug}</.link>
              <.state_badge state={env.observed_state} size="sm" />
            </li>
          </ul>
          <p :if={@environments == []} class="text-sm text-ink-3">None of yours.</p>
        </.panel>

        <.panel title="Your git identity and dotfiles here">
          <:subtitle>
            Overrides your defaults for this repo only. Empty fields use the defaults from Settings.
          </:subtitle>
          <.form for={@override_form} id="override-form" phx-submit="save_override" class="space-y-3">
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@override_form[:git_name]}
                label="Git name"
                placeholder={@current_scope.user.git_name || @current_scope.user.name}
              />
              <.input
                field={@override_form[:git_email]}
                label="Git email"
                placeholder={@current_scope.user.git_email}
              />
            </div>
            <.input
              field={@override_form[:dotfiles_repository]}
              label="Dotfiles repo"
              placeholder={
                @current_scope.user.dotfiles_repository || "https://github.com/you/dotfiles.git"
              }
            />
            <.input
              field={@override_form[:dotfiles_install_command]}
              label="Dotfiles install command"
              placeholder="./install.sh"
            />
            <.button type="submit" size="sm">Save</.button>
          </.form>
        </.panel>
      </div>

      <.panel :if={Scope.admin?(@current_scope)} title="Repo settings">
        <.form for={@settings_form} id="repo-settings" phx-submit="save_settings" class="space-y-4">
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@settings_form[:token_mode]}
              type="select"
              label="Environment GitHub token"
              options={[
                {"Scoped to this repo (recommended)", "scoped"},
                {"The user's own token (broad)", "broad"}
              ]}
            />
            <.input field={@settings_form[:default_branch]} label="Default branch" />
          </div>
          <.input
            field={@settings_form[:extra_repos]}
            label="Extra repos the scoped token can reach"
            placeholder="shared-config, design-system"
          />
          <.input
            field={@settings_form[:tailscale_tags]}
            label="Extra Tailscale tags"
            placeholder="tag:staging-access"
          />
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@settings_form[:cpu_limit]}
              type="number"
              step="0.5"
              label="Default CPU limit"
              placeholder="None"
            />
            <.input
              field={@settings_form[:memory_limit_mb]}
              type="number"
              step="256"
              label="Default memory limit (MB)"
              placeholder="None"
            />
          </div>
          <.button type="submit" size="sm">Save settings</.button>
        </.form>
      </.panel>

      <.live_component
        :if={Scope.admin?(@current_scope)}
        module={ForemanWeb.SecretsComponent}
        id="repo-secrets"
        title="Repo secrets"
        description="Every environment of this repo gets these. User and environment secrets override them."
        scope_name="repo"
        subject={@repo}
        current_scope={@current_scope}
      />
    </Layouts.app>
    """
  end
end
