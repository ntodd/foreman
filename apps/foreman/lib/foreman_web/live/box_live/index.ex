defmodule ForemanWeb.BoxLive.Index do
  @moduledoc "Boxes: their status and capacity, and (admins) adding new ones."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Boxes, Capacity, Environments, Metrics, Scope}
  alias ForemanWeb.BoxCharts

  # The cards' trend lines cover the last half hour, redrawn this often.
  @trend_range "30m"
  @trend_every 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Foreman.PubSub, "boxes")
      Metrics.subscribe_all()
    end

    {:ok,
     socket
     |> assign(:page_title, "Boxes")
     |> assign(:join, nil)
     |> assign(
       :form,
       to_form(%{"box_name" => "", "owner_user_id" => socket.assigns.current_scope.user.id},
         as: :box
       )
     )
     |> assign(
       :users,
       if(Scope.admin?(socket.assigns.current_scope), do: Accounts.list_users(), else: [])
     )
     |> load()}
  end

  defp load(socket) do
    boxes =
      for box <- Boxes.list_boxes(socket.assigns.current_scope) do
        envs = Environments.live_for_box(box.id)

        trend = Metrics.box_series(box.id, @trend_range)

        %{
          box: box,
          online: Boxes.online?(box.id),
          summary: Capacity.box_summary(box, envs),
          count: length(envs),
          trend: trend,
          latest: List.last(trend.points)
        }
      end

    assign(socket, :boxes, boxes)
  end

  defp update_card(socket, box_id, fun) do
    assign(
      socket,
      :boxes,
      Enum.map(socket.assigns.boxes, &if(&1.box.id == box_id, do: fun.(&1), else: &1))
    )
  end

  @impl true
  def handle_event("create_token", %{"box" => params}, socket) do
    case Boxes.create_join_token(socket.assigns.current_scope, params) do
      {:ok, token} ->
        name = params["box_name"]

        command =
          "curl -fsSL #{Foreman.Config.base_url()}/agent/install.sh | sudo sh -s -- --token #{token}"

        {:noreply, assign(socket, :join, %{name: name, token: token, command: command})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :box))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only admins can add boxes.")}
    end
  end

  def handle_event("done", _params, socket), do: {:noreply, assign(socket, :join, nil)}

  @impl true
  def handle_info({:box_metrics, box_id, point}, socket) do
    {:noreply,
     update_card(socket, box_id, fn card ->
       card = %{card | latest: point}

       if point.at - card.trend.until >= @trend_every,
         do: %{card | trend: Metrics.box_series(box_id, @trend_range)},
         else: card
     end)}
  end

  # Every box sends stats every 30 seconds, which only changes its
  # capacity and usage: redraw that box's card, nothing else. The trend
  # line follows box.metrics above.
  def handle_info({:box_stats, box_id}, socket) do
    shown? = Enum.any?(socket.assigns.boxes, &(&1.box.id == box_id))

    case shown? && Boxes.get_box(box_id) do
      %{} = fresh ->
        {:noreply,
         update_card(socket, box_id, fn card ->
           box = %{card.box | capacity: fresh.capacity, last_seen_at: fresh.last_seen_at}
           envs = Environments.live_for_box(box_id)

           %{
             card
             | box: box,
               online: Boxes.online?(box_id),
               summary: Capacity.box_summary(box, envs),
               count: length(envs)
           }
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="full"
    >
      <:breadcrumb>Boxes</:breadcrumb>

      <.header>
        Boxes
        <:subtitle>
          Machines running the Foreman agent. The agent dials out, so boxes need no open ports.
        </:subtitle>
      </.header>

      <div :if={@boxes != []} class="grid gap-4 md:grid-cols-2 2xl:grid-cols-3">
        <.link
          :for={card <- @boxes}
          navigate={~p"/boxes/#{card.box.id}"}
          id={"box-#{card.box.id}"}
          class={[
            "rounded-xl border bg-raised p-5 shadow-xs transition-shadow hover:shadow-raised",
            if(Foreman.Boxes.policy_exceptions(card.box) == [],
              do: "border-line",
              else: "border-danger/50 ring-1 ring-danger/30"
            )
          ]}
        >
          <div class="mb-4 flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="truncate text-[15px] font-semibold text-ink">{card.box.name}</p>
              <p class="truncate text-xs text-ink-3">
                {card.box.hostname || "never connected"}<span :if={card.box.agent_version}> · agent {card.box.agent_version}</span><span :if={
                  card.box.owner_user
                }> · {card.box.owner_user.login}</span>
              </p>
            </div>
            <div class="flex items-center gap-1.5">
              <.box_policy_badge box={card.box} />
              <.box_firewall_badge box={card.box} />
              <.box_reboot_badge box={card.box} />
              <.badge :if={card.summary.contention} color="amber" size="sm">Contention</.badge>
              <.box_status online={card.online} />
            </div>
          </div>
          <div :if={card.latest} class="mb-4 grid gap-4 sm:grid-cols-2">
            <div data-metric="cpu">
              <p class="flex items-baseline justify-between gap-2 text-xs">
                <span class="text-ink-2">CPU</span>
                <span class="font-semibold text-ink">{BoxCharts.pct(card.latest.cpu)}</span>
              </p>
              <ForemanWeb.Charts.sparkline
                points={Enum.map(card.trend.points, &{&1.at, &1.cpu})}
                since={card.trend.since}
                until={card.trend.until}
                ymax={cpu_scale(card.trend.points)}
                gap={card.trend.step * 3}
                class="mt-1.5 h-10 w-full"
              />
            </div>
            <div data-metric="memory">
              <p class="flex items-baseline justify-between gap-2 text-xs">
                <span class="text-ink-2">Memory</span>
                <span class="font-semibold text-ink">
                  {:erlang.float_to_binary(card.latest.memory_used / 1024, decimals: 1)} of {BoxCharts.gib(
                    card.latest.memory_total
                  )}
                </span>
              </p>
              <ForemanWeb.Charts.sparkline
                points={Enum.map(card.trend.points, &{&1.at, &1.memory_used})}
                since={card.trend.since}
                until={card.trend.until}
                ymax={max(card.latest.memory_total, 1)}
                gap={card.trend.step * 3}
                class="mt-1.5 h-10 w-full"
              />
            </div>
          </div>
          <div class="grid gap-3 sm:grid-cols-2">
            <.capacity_bar
              :if={is_nil(card.latest)}
              label="CPU used"
              value={card.summary.used_cpus}
              max={card.summary.cpus}
              unit=" cores"
              threshold={card.box.contention_threshold}
            />
            <.capacity_bar
              label="CPU provisioned"
              value={card.summary.provisioned_cpus}
              max={card.summary.cpus}
              unit=" cores"
              threshold={card.box.contention_threshold}
            />
            <.capacity_bar
              :if={is_nil(card.latest)}
              label="Memory used"
              value={card.summary.used_memory_mb}
              max={card.summary.memory_mb}
              unit=" GiB"
              format={&gib/1}
              threshold={card.box.contention_threshold}
            />
            <.capacity_bar
              label="Memory provisioned"
              value={card.summary.provisioned_memory_mb}
              max={card.summary.memory_mb}
              unit=" GiB"
              format={&gib/1}
              threshold={card.box.contention_threshold}
            />
          </div>
          <p class="mt-4 text-xs text-ink-3">
            {card.count} {if card.count == 1, do: "environment", else: "environments"} · placement: {card.box.capacity_policy}
          </p>
        </.link>
      </div>

      <.panel :if={@boxes == []}>
        <.empty_state id="no-boxes" icon="hero-server-stack" title="No boxes yet">
          {if Scope.admin?(@current_scope),
            do: "Add one below: it takes one command on the machine.",
            else: "Ask an admin to add a box for you."}
        </.empty_state>
      </.panel>

      <.panel :if={Scope.admin?(@current_scope)} title="Add a box" id="add-box">
        <:subtitle>Creates a single-use join token that expires in an hour.</:subtitle>
        <%= if @join do %>
          <div class="space-y-4">
            <.command
              id="install-command"
              label={"Run this on #{@join.name} (Linux with Docker, git and Node):"}
              command={@join.command}
            />
            <.callout kind="info">
              The token is shown once. The agent generates its own key and uses the token to enroll; after that, the token is spent.
            </.callout>
            <.button size="sm" phx-click="done">Done</.button>
          </div>
        <% else %>
          <.form
            for={@form}
            id="join-token-form"
            phx-submit="create_token"
            class="grid items-end gap-3 sm:grid-cols-[1fr_1fr_auto]"
          >
            <.input
              field={@form[:box_name]}
              label="Box name"
              placeholder="desktop"
              autocomplete="off"
            />
            <.input
              field={@form[:owner_user_id]}
              type="select"
              label="Owner"
              options={Enum.map(@users, &{&1.login, &1.id})}
            />
            <.button type="submit" variant="primary">Create join token</.button>
          </.form>
        <% end %>
      </.panel>
    </Layouts.app>
    """
  end

  # The CPU trend is scaled to its own peak (at least 20%), so a quiet
  # box still shows its shape; the headline carries the absolute value.
  defp cpu_scale(points) do
    peak = points |> Enum.map(& &1.cpu_max) |> Enum.max(fn -> 0 end)
    ForemanWeb.Charts.Geometry.nice_max(max(peak * 1.2, 20))
  end
end
