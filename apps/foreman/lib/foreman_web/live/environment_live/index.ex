defmodule ForemanWeb.EnvironmentLive.Index do
  @moduledoc "The home page: your environments, live, and the boxes they run on."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Boxes, Capacity, Environments, Repos}

  # States, grouped the way the filter offers them.
  @state_groups %{
    "running" => ~w(running),
    "stopped" => ~w(stopped),
    "busy" => ~w(pending creating starting stopping destroying),
    "attention" => ~w(error missing partial)
  }
  @state_order [
    {"running", "Running"},
    {"stopped", "Stopped"},
    {"busy", "Busy"},
    {"attention", "Needs attention"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Environments.subscribe_all()
      Phoenix.PubSub.subscribe(Foreman.PubSub, "boxes")
    end

    {:ok,
     socket
     |> assign(:page_title, "Environments")
     |> assign(:has_repos, Repos.list_repos(with_devcontainer: true) != [])
     |> assign(:filters, %{state: nil, box: nil})
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      state: if(params["state"] in Map.keys(@state_groups), do: params["state"]),
      box: if(params["box"] not in [nil, ""], do: params["box"])
    }

    {:noreply, socket |> assign(:filters, filters) |> derive_list()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    envs = Environments.list_environments(scope)
    envs_by_box = Enum.group_by(envs, & &1.box_id)

    socket
    |> assign(:environments, envs)
    |> assign(:boxes, Enum.map(Boxes.usable_boxes(scope), &box_card(socket, &1, envs_by_box)))
    |> derive_list()
  end

  # What the list shows, from the environments and the filters. Sections,
  # the owner column's company and the box filter only appear when there's
  # more than one person's or more than one box's to tell apart.
  defp derive_list(socket) do
    %{environments: envs, filters: filters, current_scope: scope} = socket.assigns
    me = scope.user.id

    list_boxes = envs |> Enum.map(& &1.box) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.name)
    box = if Enum.any?(list_boxes, &(&1.id == filters.box)), do: filters.box
    on_box = if box, do: Enum.filter(envs, &(&1.box_id == box)), else: envs

    counts =
      Map.new(@state_groups, fn {group, states} ->
        {group, Enum.count(on_box, &(&1.observed_state in states))}
      end)

    shown =
      if filters.state,
        do: Enum.filter(on_box, &(&1.observed_state in @state_groups[filters.state])),
        else: on_box

    {mine, others} = Enum.split_with(shown, &(&1.user_id == me))

    socket
    |> assign(:filters, %{filters | box: box})
    |> assign(:list_boxes, list_boxes)
    |> assign(:state_counts, counts)
    |> assign(:total, length(on_box))
    |> assign(:sectioned, Enum.any?(envs, &(&1.user_id != me)))
    |> assign(:mine, mine)
    |> assign(:others, Enum.sort_by(others, &{&1.user.login, &1.slug}))
  end

  defp filter_path(filters) do
    query = for {k, v} <- filters, v, do: {k, v}
    if query == [], do: ~p"/", else: ~p"/?#{query}"
  end

  # Admins see every environment, so a box's are already in the list;
  # members count everyone's on boxes shared with them.
  defp box_card(socket, box, envs_by_box) do
    envs =
      if Foreman.Scope.admin?(socket.assigns.current_scope),
        do: Map.get(envs_by_box, box.id, []),
        else: Environments.live_for_box(box.id)

    %{
      box: box,
      online: Boxes.online?(box.id),
      summary: Capacity.box_summary(box, envs),
      count: length(envs)
    }
  end

  @impl true
  # Every box sends stats every 30 seconds, which only changes its
  # capacity and usage: redraw that box's card, nothing else.
  def handle_info({:box_stats, box_id}, socket) do
    with i when is_integer(i) <- Enum.find_index(socket.assigns.boxes, &(&1.box.id == box_id)),
         %{} = fresh <- Boxes.get_box(box_id) do
      %{box: box} = Enum.at(socket.assigns.boxes, i)
      box = %{box | capacity: fresh.capacity, last_seen_at: fresh.last_seen_at}
      envs_by_box = Enum.group_by(socket.assigns.environments, & &1.box_id)
      card = box_card(socket, box, envs_by_box)
      {:noreply, assign(socket, :boxes, List.replace_at(socket.assigns.boxes, i, card))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("filter_box", %{"box" => box}, socket) do
    filters = %{socket.assigns.filters | box: if(box != "", do: box)}
    {:noreply, push_patch(socket, to: filter_path(filters))}
  end

  def handle_event("start", %{"id" => id}, socket),
    do: act(socket, id, &Environments.start/2, "Starting")

  def handle_event("stop", %{"id" => id}, socket),
    do: act(socket, id, &Environments.stop/2, "Stopping")

  def handle_event("retry", %{"id" => id}, socket),
    do: act(socket, id, &Environments.retry/2, "Retrying")

  defp act(socket, id, fun, verb) do
    env = Environments.get_environment!(socket.assigns.current_scope, id)

    case fun.(socket.assigns.current_scope, env) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "#{verb} #{env.slug}…") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(:unauthorized), do: "You can't do that to this environment."
  defp error_message(reason), do: inspect(reason)

  defp state_order, do: @state_order

  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :envs, :list, required: true
  attr :show_box, :boolean, required: true
  attr :owners, :boolean, required: true

  defp env_rows(assigns) do
    ~H"""
    <tbody id={@id} class="divide-y divide-line border-line [&:not(:first-of-type)]:border-t">
      <tr :if={@title} id={"#{@id}-heading"} class="bg-subtle">
        <%!-- One cell per column, hidden alongside them: a colspan would
             add phantom columns whenever the responsive ones are hidden. --%>
        <th class="whitespace-nowrap py-2 pl-5 text-left text-xs font-semibold text-ink-2">
          {@title} <span class="ml-1 font-normal text-ink-3">{length(@envs)}</span>
        </th>
        <td class="hidden md:table-cell"></td>
        <td :if={@show_box} class="hidden lg:table-cell"></td>
        <td></td>
        <td class="hidden 2xl:table-cell"></td>
        <td></td>
      </tr>
      <tr :for={env <- @envs} id={"env-#{env.id}"} class="group">
        <td class="py-3 pl-5 pr-3">
          <div class="flex min-w-0 items-center gap-2.5">
            <span :if={@owners} data-role="owner" title={env.user.login} class="shrink-0">
              <.avatar user={env.user} class="size-6 text-[11px]" />
            </span>
            <.link
              navigate={~p"/environments/#{env.id}"}
              class="truncate font-mono text-[14px] font-semibold text-ink hover:text-accent-ink"
            >
              {env.slug}
            </.link>
          </div>
          <p class={["mt-0.5 truncate text-xs text-ink-2 md:hidden", @owners && "pl-[34px]"]}>
            {env.repo.full_name} <span class="text-ink-3">·</span>
            <span class="font-mono">{env.branch}</span>
          </p>
        </td>
        <td class="hidden truncate py-3 pr-3 text-ink-2 md:table-cell">
          {env.repo.full_name} <span class="text-ink-3">·</span>
          <span class="font-mono text-xs">{env.branch}</span>
        </td>
        <td :if={@show_box} class="hidden truncate py-3 pr-3 text-ink-2 lg:table-cell">
          {env.box.name}
        </td>
        <td class="py-3 pr-3">
          <div class="flex flex-wrap items-center gap-1.5">
            <.state_badge state={env.observed_state} size="sm" />
            <.badge :if={env.pending_restart} color="amber" size="sm">Restart pending</.badge>
          </div>
        </td>
        <td class="hidden truncate py-3 pr-3 2xl:table-cell">
          <code
            :if={env.observed_state == "running" and env.remote_user}
            class="command text-xs text-ink-2"
          >
            ssh {env.remote_user}@{env.slug}
          </code>
        </td>
        <td class="py-3 pr-5">
          <div class="flex items-center justify-end gap-1.5">
            <.button
              :if={env.created_once and env.observed_state in ~w(stopped error missing partial)}
              size="sm"
              icon="hero-play-mini"
              phx-click="start"
              phx-value-id={env.id}
            >
              Start
            </.button>
            <.button
              :if={not env.created_once and env.observed_state == "error"}
              size="sm"
              icon="hero-arrow-path-mini"
              phx-click="retry"
              phx-value-id={env.id}
            >
              Retry
            </.button>
            <.button
              :if={env.observed_state == "running"}
              size="sm"
              variant="ghost"
              icon="hero-stop-mini"
              phx-click="stop"
              phx-value-id={env.id}
            >
              Stop
            </.button>
            <.icon_button
              icon="hero-chevron-right"
              label={"Open #{env.slug}"}
              navigate={~p"/environments/#{env.id}"}
              size="sm"
            />
          </div>
        </td>
      </tr>
    </tbody>
    """
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
      <:breadcrumb>Environments</:breadcrumb>
      <:actions>
        <.button navigate={~p"/environments/new"} variant="primary" size="sm" icon="hero-plus">
          New environment
        </.button>
      </:actions>

      <section :if={@boxes != []} id="box-strip" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.link
          :for={card <- @boxes}
          navigate={~p"/boxes/#{card.box.id}"}
          id={"box-card-#{card.box.id}"}
          class={[
            "group rounded-xl border bg-raised p-4 shadow-xs transition-shadow hover:shadow-raised",
            if(Foreman.Boxes.policy_exceptions(card.box) == [],
              do: "border-line",
              else: "border-danger/50 ring-1 ring-danger/30"
            )
          ]}
        >
          <div class="mb-3 flex items-center justify-between gap-2">
            <div class="flex min-w-0 items-center gap-2">
              <.icon name="hero-server-mini" class="size-4 shrink-0 text-ink-3" />
              <span class="truncate text-sm font-semibold text-ink">{card.box.name}</span>
            </div>
            <div class="flex items-center gap-1.5">
              <.box_policy_badge box={card.box} />
              <.box_firewall_badge box={card.box} />
              <.box_reboot_badge box={card.box} />
              <.badge :if={card.summary.contention} color="amber" size="sm">Contention</.badge>
              <.box_status online={card.online} />
            </div>
          </div>
          <div class="space-y-2.5">
            <.capacity_bar
              label="CPU"
              value={max(card.summary.used_cpus, card.summary.provisioned_cpus)}
              max={card.summary.cpus}
              unit=" cores"
              threshold={card.box.contention_threshold}
            />
            <.capacity_bar
              label="Memory"
              value={max(card.summary.used_memory_mb, card.summary.provisioned_memory_mb)}
              max={card.summary.memory_mb}
              unit=" GiB"
              format={&gib/1}
              threshold={card.box.contention_threshold}
            />
          </div>
          <p class="mt-3 text-xs text-ink-3">
            {card.count} {if card.count == 1, do: "environment", else: "environments"}
          </p>
        </.link>
      </section>

      <section :if={@environments != []} id="environments" class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <nav id="state-filter" class="segmented" aria-label="Filter by state">
            <.link
              patch={filter_path(%{@filters | state: nil})}
              data-state="all"
              aria-current={to_string(@filters.state == nil)}
            >
              All <span class="ml-1 text-ink-3">{@total}</span>
            </.link>
            <.link
              :for={{group, label} <- state_order()}
              :if={@state_counts[group] > 0 or @filters.state == group}
              patch={filter_path(%{@filters | state: group})}
              data-state={group}
              aria-current={to_string(@filters.state == group)}
            >
              {label} <span class="ml-1 text-ink-3">{@state_counts[group]}</span>
            </.link>
          </nav>

          <form :if={length(@list_boxes) > 1} id="box-filter" phx-change="filter_box">
            <label class="relative block w-48">
              <span class="sr-only">Filter by box</span>
              <select name="box" class="input h-8 text-sm">
                {Phoenix.HTML.Form.options_for_select(
                  [{"All boxes", ""} | Enum.map(@list_boxes, &{&1.name, &1.id})],
                  @filters.box || ""
                )}
              </select>
              <.icon
                name="hero-chevron-up-down-micro"
                class="pointer-events-none absolute right-2.5 top-1/2 size-4 -translate-y-1/2 text-ink-3"
              />
            </label>
          </form>
        </div>

        <.panel :if={@mine != [] or @others != []} padded={false}>
          <table class="w-full table-fixed text-sm">
            <thead class="border-b border-line text-left text-xs font-medium text-ink-3">
              <tr>
                <th class="w-[30%] py-2.5 pl-5 pr-3 font-medium md:w-[24%]">Name</th>
                <th class="hidden py-2.5 pr-3 font-medium md:table-cell">Repo</th>
                <th
                  :if={length(@list_boxes) > 1}
                  class="hidden w-[12%] py-2.5 pr-3 font-medium lg:table-cell"
                >
                  Box
                </th>
                <th class="w-36 py-2.5 pr-3 font-medium xl:w-56">State</th>
                <th class="hidden w-64 py-2.5 pr-3 font-medium 2xl:table-cell">SSH</th>
                <th class="w-40 py-2.5 pr-5"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <.env_rows
              :if={@mine != []}
              id="my-environments"
              title={if @sectioned, do: "My environments"}
              envs={@mine}
              show_box={length(@list_boxes) > 1}
              owners={@sectioned}
            />
            <.env_rows
              :if={@others != []}
              id="other-environments"
              title="Others"
              envs={@others}
              show_box={length(@list_boxes) > 1}
              owners={@sectioned}
            />
          </table>
        </.panel>

        <.panel :if={@mine == [] and @others == []}>
          <p id="no-matches" class="py-6 text-center text-sm text-ink-2">
            No environments match.
            <.link patch={~p"/"} class="font-medium text-accent-ink hover:underline">Show all</.link>
          </p>
        </.panel>
      </section>

      <.panel :if={@environments == []}>
        <.empty_state id="no-environments" icon="hero-cube-transparent" title="No environments yet">
          <%= cond do %>
            <% @boxes == [] -> %>
              Environments run on boxes: machines with the Foreman agent. Add one to get started.
            <% not @has_repos -> %>
              Foreman hasn't found a repo with a compose-based devcontainer yet.
            <% true -> %>
              Pick a repo and a box, and Foreman clones it, builds its devcontainer and joins it to your tailnet.
          <% end %>
          <:action>
            <%= cond do %>
              <% @boxes == [] -> %>
                <.button navigate={~p"/boxes"} variant="primary" icon="hero-server-stack">Add a box</.button>
              <% not @has_repos -> %>
                <.button navigate={~p"/repos"} variant="primary" icon="hero-code-bracket">Repos</.button>
              <% true -> %>
                <.button navigate={~p"/environments/new"} variant="primary" icon="hero-plus">New environment</.button>
            <% end %>
          </:action>
        </.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
