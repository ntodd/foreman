defmodule ForemanWeb.RepoLive.Index do
  @moduledoc """
  Repos Foreman knows about, from the GitHub App's installations (or
  added by hand): their totals, then each repo with its environments and
  whether new ones start from a prebuild.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Boxes, Environments, GitHub, Prebuilds, Repos, Scope}

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
    scope = socket.assigns.current_scope
    repos = Repos.list_repos(with_devcontainer: not socket.assigns.show_all)
    missing = Repos.missing_registry_credentials()

    # What the signed-in user can see of each repo: their environments
    # (everyone's, for an admin) and prebuilds on the boxes open to them.
    envs = scope |> Environments.list_environments() |> Enum.group_by(& &1.repo_id)
    prebuilt = Prebuilds.ready_box_counts(repos, Enum.map(Boxes.list_boxes(scope), & &1.id))

    rows =
      for repo <- repos do
        repo_envs = Map.get(envs, repo.id, [])

        %{
          repo: repo,
          environments: length(repo_envs),
          running: Enum.count(repo_envs, &(&1.observed_state == "running")),
          prebuilt: Map.get(prebuilt, repo.id, 0)
        }
      end

    unhealthy = MapSet.new(missing, & &1.id)

    socket
    |> assign(:rows, rows)
    |> assign(:totals, %{
      repos: length(rows),
      private: Enum.count(repos, & &1.private),
      attention: Enum.count(repos, &(&1.devcontainer_error || MapSet.member?(unhealthy, &1.id))),
      environments: Enum.sum_by(rows, & &1.environments),
      running: Enum.sum_by(rows, & &1.running),
      with_environments: Enum.count(rows, &(&1.environments > 0)),
      prebuilt: Enum.count(rows, &(&1.prebuilt > 0))
    })
    |> assign(:github, GitHub.configured?())
    |> assign(:missing_credentials, missing)
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
        {:noreply, put_flash(socket, :error, "Use the owner/name form, like acme/storefront.")}
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
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
          <.button
            :if={Foreman.Scope.admin?(@current_scope)}
            href="#add-repo"
            variant="primary"
            size="sm"
            icon="hero-plus"
          >
            Add repo
          </.button>
        </:actions>
      </.header>

      <.callout :for={repo <- @missing_credentials} kind="warning" id={"missing-cred-#{repo.id}"}>
        {repo.full_name} pulls private images ({Enum.join(repo.private_registry_refs, ", ")}), but {repo.owner.login} has no registry credential.
        <:actions :if={Foreman.Scope.admin?(@current_scope)}>
          <.button size="sm" navigate={~p"/admin"}>Add one</.button>
        </:actions>
      </.callout>

      <section
        :if={@rows != []}
        id="repo-totals"
        aria-label="Totals"
        class="card-grid grid-cols-1 sm:grid-cols-3"
      >
        <.stat_card icon="hero-code-bracket" id="repos-total" label="Repos">
          {@totals.repos}
          <:detail>
            <span :if={@totals.private > 0}>
              <span class="font-medium tabular-nums text-ink">{@totals.private}</span> private
            </span>
            <span :if={@totals.repos > @totals.private}>
              <span class="font-medium tabular-nums text-ink">{@totals.repos - @totals.private}</span>
              public
            </span>
          </:detail>
          <:note>
            <span :if={@totals.attention > 0} class="inline-flex items-center gap-1 text-warning">
              <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
              {@totals.attention} {if @totals.attention == 1, do: "needs", else: "need"} attention
            </span>
            <span :if={@totals.attention == 0} class="inline-flex items-center gap-1 text-success">
              <.icon name="hero-check-circle-micro" class="size-3.5" /> All healthy
            </span>
          </:note>
        </.stat_card>
        <.stat_card icon="hero-cube" id="repos-environments" label="Environments">
          {@totals.environments}
          <:detail :if={@totals.environments > 0}>
            <span>
              <span class="font-medium tabular-nums text-ink">{@totals.running}</span> running
            </span>
          </:detail>
          <:note>
            {if @totals.environments == 0,
              do: "None yet",
              else:
                "In #{@totals.with_environments} #{if @totals.with_environments == 1, do: "repo", else: "repos"}"}
          </:note>
        </.stat_card>
        <.stat_card icon="hero-bolt" id="repos-prebuilds" label="Prebuilt">
          {@totals.prebuilt} <span class="text-base font-medium text-ink-3">of {@totals.repos}</span>
          <:note>New environments start from a prebuild</:note>
        </.stat_card>
      </section>

      <.panel :if={@rows != []} padded={false}>
        <ul class="divide-y divide-line">
          <li :for={%{repo: repo} = row <- @rows} id={"repo-#{repo.id}"}>
            <.link
              navigate={~p"/repos/#{repo.id}"}
              class="flex items-center gap-3 px-5 py-3 transition-colors hover:bg-subtle"
            >
              <.icon
                name={if repo.private, do: "hero-lock-closed-mini", else: "hero-globe-alt-mini"}
                class="size-4 shrink-0 text-ink-3"
              />
              <%!-- What the repo has drops under the name on phones, so the name keeps the row's width. --%>
              <div class="flex min-w-0 flex-1 flex-col gap-1.5 sm:flex-row sm:items-center sm:gap-3">
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium text-ink">{repo.full_name}</p>
                  <p class="truncate text-xs text-ink-3">
                    {repo.default_branch}
                    <span :if={repo.devcontainer_path}>· {repo.devcontainer_path}</span>
                    <span :if={repo.manual}>· added by hand</span>
                  </p>
                </div>
                <div :if={tags?(row)} class="flex flex-wrap items-center gap-x-3 gap-y-1.5">
                  <span
                    :if={row.environments > 0}
                    data-role="environments"
                    class="inline-flex items-center gap-1.5 whitespace-nowrap text-xs tabular-nums text-ink-2"
                  >
                    <span
                      class={[
                        "size-1.5 rounded-full",
                        if(row.running > 0, do: "bg-success", else: "bg-line-strong")
                      ]}
                      aria-hidden="true"
                    />
                    <span>
                      {row.environments} {if row.environments == 1,
                        do: "environment",
                        else: "environments"}<span :if={row.running > 0} class="text-ink-3"> · {row.running} running</span>
                    </span>
                  </span>
                  <.badge
                    :if={row.prebuilt > 0}
                    color="emerald"
                    size="sm"
                    data-role="prebuilt"
                    title={"New environments start from a prebuild on #{row.prebuilt} #{if row.prebuilt == 1, do: "box", else: "boxes"}"}
                  >
                    Prebuilt
                  </.badge>
                  <.badge :if={repo.devcontainer_error} color="amber" size="sm">
                    {repo.devcontainer_error}
                  </.badge>
                  <.badge :if={is_nil(repo.devcontainer_path)} size="sm">No devcontainer</.badge>
                  <.badge :if={repo.token_mode == "broad"} color="amber" size="sm">
                    Broad token
                  </.badge>
                </div>
              </div>
              <.icon name="hero-chevron-right-mini" class="size-4 text-ink-3" />
            </.link>
          </li>
        </ul>
      </.panel>

      <.panel :if={@rows == []}>
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

      <.panel
        :if={Foreman.Scope.admin?(@current_scope)}
        id="add-repo"
        title="Add a repo by name"
        split
      >
        <:subtitle>For public repos outside the app's installations.</:subtitle>
        <.form for={@add_form} id="add-repo-form" phx-submit="add" class="flex items-start gap-2">
          <div class="min-w-0 flex-1">
            <.input
              field={@add_form[:full_name]}
              aria-label="Repository name"
              placeholder="owner/name"
            />
          </div>
          <.button type="submit">Add</.button>
        </.form>
      </.panel>
    </Layouts.app>
    """
  end

  # Whether a row has anything to show beside the repo's name.
  defp tags?(%{repo: repo} = row) do
    row.environments > 0 or row.prebuilt > 0 or repo.devcontainer_error != nil or
      is_nil(repo.devcontainer_path) or repo.token_mode == "broad"
  end
end
