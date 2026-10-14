defmodule ForemanWeb.EnvironmentLive.New do
  @moduledoc "Create an environment: pick a repo, a branch and a box."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Boxes, Capacity, Environments, GitHub, Repos}

  @impl true
  def mount(params, _session, socket) do
    repos = Repos.list_repos(with_devcontainer: true)
    boxes = Boxes.usable_boxes(socket.assigns.current_scope)

    repo_id = params["repo_id"] || (List.first(repos) && List.first(repos).id)

    box_id =
      boxes
      |> Enum.find(&Boxes.online?(&1.id))
      |> Kernel.||(List.first(boxes))
      |> then(&(&1 && &1.id))

    form = %{
      "repo_id" => repo_id,
      "box_id" => box_id,
      "branch" => "",
      "cpu_limit" => "",
      "memory_limit_mb" => ""
    }

    {:ok,
     socket
     |> assign(:page_title, "New environment")
     |> assign(:repos, repos)
     |> assign(:boxes, boxes)
     |> assign(:confirm, nil)
     |> assign(:error, nil)
     |> assign(:branches, [])
     |> assign_form(form)
     |> load_branches()}
  end

  defp assign_form(socket, params) do
    repo = Enum.find(socket.assigns.repos, &(&1.id == params["repo_id"]))
    box = Enum.find(socket.assigns.boxes, &(&1.id == params["box_id"]))

    placement =
      if repo && box do
        limits = %{
          cpu_limit: number(params["cpu_limit"]),
          memory_limit_mb: number(params["memory_limit_mb"])
        }

        Capacity.check_placement(box, Environments.live_for_box(box.id), repo, limits)
      end

    socket
    |> assign(:form, to_form(params, as: :environment))
    |> assign(:repo, repo)
    |> assign(:box, box)
    |> assign(:placement, placement)
  end

  defp load_branches(%{assigns: %{repo: nil}} = socket), do: assign(socket, :branches, [])

  defp load_branches(%{assigns: %{repo: repo, current_scope: scope}} = socket) do
    if connected?(socket) and GitHub.configured?() and scope.user.access_token do
      start_async(socket, :branches, fn -> GitHub.list_branches(scope.user, repo) end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:branches, {:ok, {:ok, branches}}, socket),
    do: {:noreply, assign(socket, :branches, Enum.take(branches, 300))}

  def handle_async(:branches, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change", %{"environment" => params}, socket) do
    repo_changed? = params["repo_id"] != socket.assigns.form.params["repo_id"]
    socket = socket |> assign(:confirm, nil) |> assign(:error, nil) |> assign_form(params)
    {:noreply, if(repo_changed?, do: load_branches(assign(socket, :branches, [])), else: socket)}
  end

  def handle_event("create", %{"environment" => params}, socket) do
    params = if socket.assigns.confirm, do: Map.put(params, "confirm", "true"), else: params

    case Environments.create_environment(socket.assigns.current_scope, params) do
      {:ok, env} ->
        {:noreply,
         socket
         |> put_flash(:info, "Creating #{env.slug}. The first build can take a few minutes.")
         |> push_navigate(to: ~p"/environments/#{env.id}")}

      {:confirm, message} ->
        {:noreply, assign(socket, confirm: message, error: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :error, changeset_message(changeset))}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error, message)}
    end
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp number(""), do: nil
  defp number(nil), do: nil

  defp number(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp repo_options(repos) do
    repos
    |> Enum.group_by(& &1.owner.login)
    |> Enum.sort()
    |> Enum.map(fn {owner, repos} -> {owner, Enum.map(repos, &{&1.name, &1.id})} end)
  end

  defp box_options(boxes) do
    Enum.map(boxes, fn box ->
      label = if Boxes.online?(box.id), do: box.name, else: "#{box.name} (offline)"
      {label, box.id}
    end)
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
      <:breadcrumb navigate={~p"/"}>Environments</:breadcrumb>
      <:breadcrumb>New</:breadcrumb>

      <.header>
        New environment
        <:subtitle>
          Foreman clones the repo onto the box, builds its devcontainer, and joins it to your tailnet.
        </:subtitle>
      </.header>

      <.panel :if={@repos == [] or @boxes == []}>
        <.empty_state
          :if={@boxes == []}
          id="no-boxes"
          icon="hero-server-stack"
          title="No boxes you can use"
        >
          An admin needs to add a box (or share one with you) first.
        </.empty_state>
        <.empty_state
          :if={@boxes != [] and @repos == []}
          id="no-repos"
          icon="hero-code-bracket"
          title="No repos with a devcontainer"
        >
          Foreman lists repos the GitHub App can see that have a compose-based devcontainer.
          <:action><.button navigate={~p"/repos"}>Repos</.button></:action>
        </.empty_state>
      </.panel>

      <.form
        :if={@repos != [] and @boxes != []}
        for={@form}
        id="new-environment"
        phx-change="change"
        phx-submit="create"
        class="space-y-6"
      >
        <.panel>
          <div class="space-y-5">
            <.input field={@form[:repo_id]} type="select" label="Repo" options={repo_options(@repos)} />

            <div :if={@repo} class="-mt-2 space-y-2">
              <div class="flex flex-wrap gap-1.5 text-xs text-ink-2">
                <.badge size="sm">{@repo.devcontainer_path}</.badge>
                <.badge :if={@repo.host_requirements} size="sm">
                  Wants {@repo.host_requirements["cpus"] || "?"} CPUs, {@repo.host_requirements[
                    "memory"
                  ] || "?"} memory
                </.badge>
                <.badge :if={@repo.token_mode == "broad"} color="amber" size="sm">
                  Unscoped GitHub token
                </.badge>
              </div>
              <.callout :if={@repo.devcontainer_error} kind="warning">
                {@repo.devcontainer_error}
              </.callout>
              <.callout
                :if={@repo.private_registry_refs != [] and is_nil(@repo.owner.registry_token)}
                kind="warning"
              >
                This devcontainer pulls from a private registry ({Enum.join(
                  @repo.private_registry_refs,
                  ", "
                )}) and {@repo.owner.login} has no registry credential yet, so the build will fail. An admin can add one under Deployment.
              </.callout>
            </div>

            <div>
              <.input
                field={@form[:branch]}
                label="Branch"
                placeholder={(@repo && @repo.default_branch) || "main"}
                list="branch-options"
                autocomplete="off"
              />
              <datalist id="branch-options">
                <option :for={branch <- @branches} value={branch} />
              </datalist>
              <p class="mt-1.5 text-xs text-ink-3">Leave empty for the default branch.</p>
            </div>

            <.input field={@form[:box_id]} type="select" label="Box" options={box_options(@boxes)} />
          </div>
        </.panel>

        <details class="group rounded-xl border border-line bg-raised shadow-xs">
          <summary class="flex cursor-pointer list-none items-center justify-between px-5 py-3.5 text-sm font-semibold text-ink">
            Resource limits
            <span class="text-xs font-normal text-ink-3 group-open:hidden">None: it takes what it can get</span>
          </summary>
          <div class="grid gap-4 border-t border-line p-5 sm:grid-cols-2">
            <.input
              field={@form[:cpu_limit]}
              type="number"
              step="0.5"
              min="0.5"
              label="CPUs"
              placeholder={(@repo && @repo.cpu_limit) || "No limit"}
            />
            <.input
              field={@form[:memory_limit_mb]}
              type="number"
              step="256"
              min="256"
              label="Memory (MB)"
              placeholder={(@repo && @repo.memory_limit_mb) || "No limit"}
            />
          </div>
        </details>

        <.callout :if={match?({:contention, _}, @placement)} kind="info" id="placement-contention">
          {elem(@placement, 1)}. Foreman will place it anyway; this box allows overcommit.
        </.callout>
        <.callout
          :if={match?({:warn, _}, @placement) and is_nil(@confirm)}
          kind="warning"
          id="placement-warn"
        >
          {elem(@placement, 1)}. You'll be asked to confirm.
        </.callout>
        <.callout :if={match?({:refuse, _}, @placement)} kind="danger" id="placement-refuse">
          {elem(@placement, 1)}. This box refuses placements past its capacity.
        </.callout>
        <.callout :if={@confirm} kind="warning" id="confirm-placement">
          {@confirm}. Create it anyway?
        </.callout>
        <.callout :if={@error} kind="danger" id="create-error">{@error}</.callout>

        <div class="flex items-center justify-end gap-2">
          <.button navigate={~p"/"} variant="ghost">Cancel</.button>
          <.button
            type="submit"
            variant="primary"
            icon="hero-rocket-launch"
            phx-disable-with="Creating…"
          >
            {if @confirm, do: "Create anyway", else: "Create environment"}
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
