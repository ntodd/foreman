defmodule ForemanWeb.EnvironmentLive.Index do
  @moduledoc "The home page: your environments, live, and the boxes they run on."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Boxes, Capacity, Environments, Repos}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Environments.subscribe_all()
      Phoenix.PubSub.subscribe(Foreman.PubSub, "boxes")
    end

    {:ok, socket |> assign(:page_title, "Environments") |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    envs = Environments.list_environments(scope)
    boxes = Boxes.usable_boxes(scope)
    all_envs_by_box = Enum.group_by(envs, & &1.box_id)

    box_cards =
      for box <- boxes do
        envs =
          if Foreman.Scope.admin?(scope),
            do: Map.get(all_envs_by_box, box.id, []),
            else: Environments.live_for_box(box.id)

        %{
          box: box,
          online: Boxes.online?(box.id),
          summary: Capacity.box_summary(box, envs),
          count: length(envs)
        }
      end

    socket
    |> assign(:environments, envs)
    |> assign(:boxes, box_cards)
    |> assign(:has_repos, Repos.list_repos(with_devcontainer: true) != [])
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("start", %{"id" => id}, socket),
    do: act(socket, id, &Environments.start/2, "Starting")

  def handle_event("stop", %{"id" => id}, socket),
    do: act(socket, id, &Environments.stop/2, "Stopping")

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
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

      <.panel :if={@environments != []} padded={false} id="environments">
        <ul class="divide-y divide-line">
          <li
            :for={env <- @environments}
            id={"env-#{env.id}"}
            class="flex flex-wrap items-center gap-x-4 gap-y-2 px-5 py-3.5"
          >
            <div class="min-w-0 flex-1 basis-60">
              <div class="flex items-center gap-2">
                <.link
                  navigate={~p"/environments/#{env.id}"}
                  class="truncate font-mono text-[15px] font-semibold text-ink hover:text-accent-ink"
                >
                  {env.slug}
                </.link>
                <.state_badge state={env.observed_state} size="sm" />
                <.badge :if={env.pending_restart} color="amber" size="sm">Restart pending</.badge>
              </div>
              <p class="mt-0.5 truncate text-xs text-ink-2">
                {env.repo.full_name}
                <span class="text-ink-3">·</span>
                <span class="font-mono">{env.branch}</span>
                <span class="text-ink-3">· on {env.box.name}</span>
                <span
                  :if={Foreman.Scope.admin?(@current_scope) and env.user_id != @current_scope.user.id}
                  class="text-ink-3"
                >
                  · {env.user.login}
                </span>
              </p>
            </div>

            <code
              :if={env.observed_state == "running" and env.remote_user}
              class="command hidden text-xs text-ink-2 md:block"
            >
              ssh {env.remote_user}@{env.slug}
            </code>

            <div class="flex items-center gap-1.5">
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
          </li>
        </ul>
      </.panel>

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
