defmodule ForemanWeb.RepoLive.Index do
  @moduledoc "Repos Foreman knows about, from the GitHub App's installations (or added by hand)."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{GitHub, Repos, Scope}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Repos")
     |> assign(:show_all, false)
     |> assign(:syncing, false)
     |> assign(:add_form, to_form(%{"full_name" => ""}, as: :repo))
     |> load()}
  end

  defp load(socket) do
    repos = Repos.list_repos(with_devcontainer: not socket.assigns.show_all)

    socket
    |> assign(:repos, repos)
    |> assign(:github, GitHub.configured?())
    |> assign(:missing_credentials, Repos.missing_registry_credentials())
  end

  @impl true
  def handle_event("toggle_all", _params, socket) do
    {:noreply, socket |> update(:show_all, &(not &1)) |> load()}
  end

  def handle_event("sync", _params, socket) do
    if Scope.admin?(socket.assigns.current_scope) do
      {:noreply,
       socket |> assign(:syncing, true) |> start_async(:sync, fn -> GitHub.sync_repos() end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add", %{"repo" => %{"full_name" => name}}, socket) do
    case Repos.add_repo(socket.assigns.current_scope, String.trim(name), %{
           devcontainer_path: ".devcontainer/devcontainer.json"
         }) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added #{repo.full_name}.")
         |> push_navigate(to: ~p"/repos/#{repo.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Use the owner/name form, like ntodd/storefront.")}
    end
  end

  @impl true
  def handle_async(:sync, {:ok, {:ok, count}}, socket) do
    {:noreply,
     socket |> assign(:syncing, false) |> put_flash(:info, "Synced #{count} repos.") |> load()}
  end

  def handle_async(:sync, result, socket) do
    {:noreply,
     socket |> assign(:syncing, false) |> put_flash(:error, "Sync failed: #{inspect(result)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <:breadcrumb>Repos</:breadcrumb>
      <:actions>
        <.button
          :if={@github and Foreman.Scope.admin?(@current_scope)}
          size="sm"
          icon="hero-arrow-path-mini"
          phx-click="sync"
          disabled={@syncing}
        >
          {if @syncing, do: "Syncing…", else: "Sync from GitHub"}
        </.button>
      </:actions>

      <.header>
        Repos
        <:subtitle>
          {if @show_all,
            do: "Everything the GitHub App can see.",
            else: "Repos with a devcontainer, which Foreman can make environments from."}
        </:subtitle>
        <:actions>
          <label class="flex cursor-pointer items-center gap-2 text-sm text-ink-2">
            <input type="checkbox" class="switch" checked={@show_all} phx-click="toggle_all" />
            Show all
          </label>
        </:actions>
      </.header>

      <.callout :for={repo <- @missing_credentials} kind="warning" id={"missing-cred-#{repo.id}"}>
        {repo.full_name} pulls private images ({Enum.join(repo.private_registry_refs, ", ")}), but {repo.owner.login} has no registry credential.
        <:actions :if={Foreman.Scope.admin?(@current_scope)}>
          <.button size="sm" navigate={~p"/admin"}>Add one</.button>
        </:actions>
      </.callout>

      <.panel :if={@repos != []} padded={false}>
        <ul class="divide-y divide-line">
          <li :for={repo <- @repos} id={"repo-#{repo.id}"}>
            <.link
              navigate={~p"/repos/#{repo.id}"}
              class="flex items-center gap-3 px-5 py-3 transition-colors hover:bg-subtle"
            >
              <.icon
                name={if repo.private, do: "hero-lock-closed-mini", else: "hero-globe-alt-mini"}
                class="size-4 shrink-0 text-ink-3"
              />
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm font-medium text-ink">{repo.full_name}</p>
                <p class="truncate text-xs text-ink-3">
                  {repo.default_branch}
                  <span :if={repo.devcontainer_path}>· {repo.devcontainer_path}</span>
                  <span :if={repo.manual}>· added by hand</span>
                </p>
              </div>
              <.badge :if={repo.devcontainer_error} color="amber" size="sm">
                {repo.devcontainer_error}
              </.badge>
              <.badge :if={is_nil(repo.devcontainer_path)} size="sm">No devcontainer</.badge>
              <.badge :if={repo.token_mode == "broad"} color="amber" size="sm">Broad token</.badge>
              <.icon name="hero-chevron-right-mini" class="size-4 text-ink-3" />
            </.link>
          </li>
        </ul>
      </.panel>

      <.panel :if={@repos == []}>
        <.empty_state
          id="no-repos"
          icon="hero-code-bracket"
          title={if @github, do: "No repos yet", else: "GitHub isn't connected"}
        >
          {if @github,
            do:
              "Install the GitHub App on an account, then sync. Repos show up here once Foreman finds a devcontainer.",
            else: "Finish setup to connect the GitHub App, or add a public repo by name below."}
        </.empty_state>
      </.panel>

      <.panel :if={Foreman.Scope.admin?(@current_scope)} title="Add a repo by name">
        <:subtitle>For public repos outside the app's installations.</:subtitle>
        <.form for={@add_form} id="add-repo" phx-submit="add" class="flex items-end gap-2">
          <div class="flex-1"><.input field={@add_form[:full_name]} placeholder="owner/name" /></div>
          <.button type="submit">Add</.button>
        </.form>
      </.panel>
    </Layouts.app>
    """
  end
end
