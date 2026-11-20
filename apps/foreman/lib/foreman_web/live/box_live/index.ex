defmodule ForemanWeb.BoxLive.Index do
  @moduledoc """
  Boxes: the fleet's totals, a card per box with its status, its last
  half hour of CPU and memory and what's provisioned on it, and (admins)
  adding new ones.
  """
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Boxes, Capacity, Environments, Metrics, Scope}
  alias ForemanWeb.{BoxCharts, Fleet}

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
     |> assign(:tailscale?, Foreman.Tailscale.configured?())
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
    params = Map.update(params, "tailscale_auth_key", nil, &blank_to_nil/1)

    case Boxes.create_join_token(socket.assigns.current_scope, params) do
      {:ok, token} ->
        join = %{name: params["box_name"], token: token, kind: "linux", ignition: nil}
        {:noreply, assign(socket, :join, join)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :box))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only admins can add boxes.")}
    end
  end

  def handle_event("join_kind", %{"kind" => kind}, %{assigns: %{join: %{} = join}} = socket)
      when kind in ["linux", "vm", "flatcar"] do
    join = %{join | kind: kind}

    # The configs carry the box's Tailscale key, minted the first time.
    join =
      if kind == "flatcar" and is_nil(join.ignition),
        do: %{join | ignition: ignition_downloads(join.token)},
        else: join

    {:noreply, assign(socket, :join, join)}
  end

  def handle_event("done", _params, socket), do: {:noreply, assign(socket, :join, nil)}

  defp ignition_downloads(token) do
    Enum.reduce_while(Foreman.Boxes.Flatcar.arches(), {:ok, []}, fn arch, {:ok, acc} ->
      case Boxes.flatcar_ignition(token, %{"arch" => arch}) do
        {:ok, config, _name} ->
          url = "data:application/json;base64," <> Base.encode64(JSON.encode!(config))
          {:cont, {:ok, acc ++ [{arch, url}]}}

        {:error, {:tailscale, reason}} ->
          {:halt, {:error, "Tailscale wouldn't mint the box a key: #{inspect(reason)}"}}

        {:error, reason} ->
          {:halt, {:error, "couldn't make the config: #{inspect(reason)}"}}
      end
    end)
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(value), do: value

  defp join_command(%{kind: kind, token: token}) do
    url = Foreman.Config.base_url()

    case kind do
      "vm" -> "curl -fsSL #{url}/agent/vm.sh | sudo sh -s -- --token #{token}"
      _ -> "curl -fsSL #{url}/agent/install.sh | sudo sh -s -- --token #{token}"
    end
  end

  defp join_label(%{kind: "vm", name: name}),
    do:
      "Run this on the Linux machine that hosts #{name}. It needs KVM with nested virtualization, and runs the box as a Flatcar VM under QEMU, apart from the host and updating itself. Environments run nested in it, which is slower than a box on the machine itself:"

  defp join_label(%{name: name}),
    do:
      "Run this on #{name} (amd64 Linux with KVM, systemd, nftables, iproute2 and e2fsprogs; each environment runs in a VM of its own):"

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
      content_class="card-grid grid-cols-1"
    >
      <:breadcrumb>Boxes</:breadcrumb>

      <.header class="pb-0!">
        Boxes
        <:subtitle>
          Machines running the Foreman agent. The agent dials out, so boxes need no open ports.
        </:subtitle>
        <:actions>
          <span
            :if={@boxes != []}
            id="boxes-live"
            class="mr-1 inline-flex items-center gap-1.5 text-xs text-ink-3"
            title="Usage updates as the boxes report it"
          >
            <span class="size-1.5 rounded-full bg-success motion-safe:animate-status-pulse" /> Live
          </span>
          <.button
            :if={Scope.admin?(@current_scope)}
            href="#add-box"
            variant="primary"
            size="sm"
            icon="hero-plus"
          >
            Add box
          </.button>
        </:actions>
      </.header>

      <section :if={@boxes != []} id="fleet" aria-label="Fleet" class="@container">
        <.totals totals={Fleet.totals(@boxes)} />
      </section>

      <section :if={@boxes != []} aria-label="Boxes" class="@container">
        <div id="boxes-grid" class={["card-grid", grid_cols(length(@boxes))]}>
          <.box_card :for={card <- @boxes} card={card} />
        </div>
      </section>

      <.panel :if={@boxes == []}>
        <.empty_state id="no-boxes" icon="hero-server-stack" title="No boxes yet">
          {if Scope.admin?(@current_scope),
            do: "Add one below: it takes one command on the machine.",
            else: "Ask an admin to add a box for you."}
        </.empty_state>
      </.panel>

      <.panel :if={Scope.admin?(@current_scope)} title="Add a box" id="add-box" split={is_nil(@join)}>
        <:subtitle>Creates a single-use join token that expires in an hour.</:subtitle>
        <%= if @join do %>
          <div class="space-y-4">
            <div id="join-kinds" class="inline-flex rounded-lg border border-line-strong p-0.5">
              <button
                :for={
                  {kind, label} <- [
                    {"linux", "Linux"},
                    {"vm", "Linux VM"},
                    {"flatcar", "Flatcar"}
                  ]
                }
                type="button"
                phx-click="join_kind"
                phx-value-kind={kind}
                aria-pressed={to_string(@join.kind == kind)}
                class={[
                  "rounded-md px-3 py-1 text-xs font-medium transition-colors",
                  if(@join.kind == kind,
                    do: "bg-subtle text-ink shadow-control",
                    else: "text-ink-2 hover:text-ink"
                  )
                ]}
              >
                {label}
              </button>
            </div>
            <.command
              :if={@join.kind != "flatcar"}
              id="install-command"
              label={join_label(@join)}
              command={join_command(@join)}
            />
            <div
              :if={@join.kind == "flatcar"}
              id="flatcar-config"
              class="space-y-3 text-sm text-ink-2"
            >
              <p>
                For bare metal, or any other hypervisor: boot Flatcar Container Linux with this first-boot config. On bare metal, from Flatcar's live image: <code class="font-mono text-xs">flatcar-install -d /dev/sda -i {@join.name}-amd64.ign</code>. The box sets itself up and enrolls on its first boot.
              </p>
              <%= case @join.ignition do %>
                <% {:ok, downloads} -> %>
                  <div class="flex flex-wrap gap-2">
                    <a
                      :for={{arch, url} <- downloads}
                      id={"ignition-#{arch}"}
                      href={url}
                      download={"#{@join.name}-#{arch}.ign"}
                      class="inline-flex items-center gap-1.5 rounded-lg border border-line-strong bg-canvas px-3 py-1.5 text-xs font-medium text-ink shadow-control hover:bg-subtle"
                    >
                      <.icon name="hero-arrow-down-tray-micro" class="size-3.5" />
                      {@join.name}-{arch}.ign
                    </a>
                  </div>
                <% {:error, message} -> %>
                  <.callout kind="danger">{message}</.callout>
                <% nil -> %>
              <% end %>
              <p class="text-xs">
                The config holds the join token{if @tailscale?,
                  do:
                    " and a single-use Tailscale key tagged #{Enum.join(Foreman.Tailscale.box_tags(), ", ")}",
                  else: ""}; keep it to yourself.
              </p>
            </div>
            <.callout
              :if={@join.kind in ["vm", "flatcar"] and not @tailscale?}
              kind="warning"
            >
              Without a Tailscale OAuth client, a Flatcar box only joins the tailnet with a key pasted when the token was made. Without one, it reaches Foreman only if its network can (its host's tailnet, say).
            </.callout>
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
            class={[
              "grid items-start gap-3 sm:grid-cols-2",
              @tailscale? && "sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]"
            ]}
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
            <.input
              :if={not @tailscale?}
              field={@form[:tailscale_auth_key]}
              type="password"
              label="Tailscale auth key, for a Flatcar box (optional)"
              placeholder="tskey-auth-..."
              autocomplete="off"
            />
            <.button type="submit" variant="primary" class="sm:self-end sm:justify-self-start">
              Create join token
            </.button>
          </.form>
        <% end %>
      </.panel>
    </Layouts.app>
    """
  end

  # -- the fleet ----------------------------------------------------------------------

  attr :totals, :map, required: true

  defp totals(assigns) do
    ~H"""
    <div class="card-grid grid-cols-2 @4xl:grid-cols-4">
      <.stat_card icon="hero-server-stack" id="fleet-boxes" label="Boxes online">
        {@totals.online} <span class="text-base font-medium text-ink-3">of {@totals.boxes}</span>
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
      <.stat_card icon="hero-cpu-chip" id="fleet-cores" label="Cores">
        {Fleet.cores(@totals.cpus)}
        <:detail>
          <span>
            <span class="font-medium tabular-nums text-ink">{Fleet.cores(@totals.provisioned_cpus)}</span>
            provisioned
          </span>
          <span>
            <span class="font-medium tabular-nums text-ink">{Fleet.cores(@totals.used_cpus)}</span>
            in use
          </span>
        </:detail>
        <:note>On the online boxes</:note>
      </.stat_card>
      <.stat_card icon="hero-square-3-stack-3d" id="fleet-memory" label="Memory">
        {gib(@totals.memory_mb)} <span class="text-base font-medium text-ink-3">GiB</span>
        <:detail>
          <span>
            <span class="font-medium tabular-nums text-ink">{gib(@totals.provisioned_memory_mb)} GiB</span>
            provisioned
          </span>
          <span>
            <span class="font-medium tabular-nums text-ink">{gib(@totals.used_memory_mb)} GiB</span>
            in use
          </span>
        </:detail>
        <:note>On the online boxes</:note>
      </.stat_card>
      <.stat_card icon="hero-cube" id="fleet-environments" label="Environments">
        {@totals.environments}
        <:detail :if={@totals.disk_free_mb}>
          <span>
            <span class="font-medium tabular-nums text-ink">{gib(@totals.disk_free_mb)} GiB</span>
            of disk free
          </span>
        </:detail>
        <:note>
          On {@totals.boxes} {if @totals.boxes == 1, do: "box", else: "boxes"}
        </:note>
      </.stat_card>
    </div>
    """
  end

  # -- a box ---------------------------------------------------------------------------

  # Three or four boxes fill a row on a wide screen; one or two get wider
  # cards, which lay out their trends beside what's provisioned.
  defp grid_cols(1), do: "grid-cols-1"
  defp grid_cols(2), do: "grid-cols-1 @3xl:grid-cols-2"
  defp grid_cols(3), do: "grid-cols-1 @2xl:grid-cols-2 @5xl:grid-cols-3"
  defp grid_cols(4), do: "grid-cols-1 @2xl:grid-cols-2 @7xl:grid-cols-4"
  defp grid_cols(_), do: "grid-cols-1 @2xl:grid-cols-2 @5xl:grid-cols-3 @[100rem]:grid-cols-4"

  attr :card, :map, required: true

  defp box_card(assigns) do
    # Being offline is the status badge's to say; the rest get a row of their own.
    alerts = Enum.any?(Fleet.issues(assigns.card), &(&1.role != "offline"))
    assigns = assign(assigns, id: "box-#{assigns.card.box.id}", alerts: alerts)

    ~H"""
    <.link
      navigate={~p"/boxes/#{@card.box.id}"}
      id={@id}
      class={[
        "@container flex flex-col rounded-xl border bg-raised shadow-xs transition-colors",
        if(Foreman.Boxes.vm_problem(@card.box) == nil,
          do: "border-line hover:border-line-strong",
          else: "border-danger/50 ring-1 ring-danger/30"
        )
      ]}
    >
      <div class="flex items-start justify-between gap-3 px-5 pt-4">
        <div class="min-w-0">
          <p class="truncate font-semibold text-ink">{@card.box.name}</p>
          <p class="mt-0.5 truncate text-xs text-ink-3">
            {@card.box.hostname || "never connected"}<span :if={@card.box.agent_version}> · agent {@card.box.agent_version}</span><span :if={
              @card.box.owner_user
            }> · {@card.box.owner_user.login}</span>
          </p>
        </div>
        <.box_status online={@card.online} />
      </div>

      <div :if={@alerts} id={"#{@id}-issues"} class="mt-3 flex flex-wrap items-center gap-1.5 px-5">
        <.box_vm_badge box={@card.box} />
        <.box_firewall_badge box={@card.box} />
        <.box_reboot_badge box={@card.box} />
        <.badge :if={@card.summary.contention} color="amber" size="sm">Contention</.badge>
      </div>

      <div class="grid flex-1 content-start gap-x-8 gap-y-4 px-5 py-4 @3xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div :if={@card.latest} class="grid grid-cols-2 gap-4">
          <div data-metric="cpu">
            <p class="flex items-baseline justify-between gap-2 text-xs">
              <span class="text-ink-2">CPU</span>
              <span class="font-semibold tabular-nums text-ink">{BoxCharts.pct(@card.latest.cpu)}</span>
            </p>
            <ForemanWeb.Charts.sparkline
              points={Enum.map(@card.trend.points, &{&1.at, &1.cpu})}
              since={@card.trend.since}
              until={@card.trend.until}
              ymax={cpu_scale(@card.trend.points)}
              gap={@card.trend.step * 3}
              class="mt-2 h-12 w-full @3xl:h-20"
            />
          </div>
          <div data-metric="memory">
            <p class="flex items-baseline justify-between gap-2 text-xs">
              <span class="text-ink-2">Memory</span>
              <span class="truncate font-semibold tabular-nums text-ink">
                {:erlang.float_to_binary(@card.latest.memory_used / 1024, decimals: 1)}
                <span class="font-normal text-ink-3">of {BoxCharts.gib(@card.latest.memory_total)}</span>
              </span>
            </p>
            <ForemanWeb.Charts.sparkline
              points={Enum.map(@card.trend.points, &{&1.at, &1.memory_used})}
              since={@card.trend.since}
              until={@card.trend.until}
              ymax={max(@card.latest.memory_total, 1)}
              gap={@card.trend.step * 3}
              class="mt-2 h-12 w-full @3xl:h-20"
            />
          </div>
        </div>
        <%!-- A box that hasn't sent host metrics shows what its environments use instead. --%>
        <div :if={is_nil(@card.latest)} class="grid grid-cols-2 gap-4">
          <.capacity_bar
            label="CPU used"
            value={@card.summary.used_cpus}
            max={@card.summary.cpus}
            unit=" cores"
            threshold={Capacity.used_threshold(@card.box.cpu_threshold)}
          />
          <.capacity_bar
            label="Memory used"
            value={@card.summary.used_memory_mb}
            max={@card.summary.memory_mb}
            unit=" GiB"
            format={&gib/1}
            threshold={Capacity.used_threshold(@card.box.memory_threshold)}
          />
        </div>

        <div class="space-y-3">
          <.capacity_bar
            label="CPU provisioned"
            value={@card.summary.provisioned_cpus}
            max={@card.summary.cpus}
            unit=" cores"
            threshold={@card.box.cpu_threshold}
          />
          <.capacity_bar
            label="Memory provisioned"
            value={@card.summary.provisioned_memory_mb}
            max={@card.summary.memory_mb}
            unit=" GiB"
            format={&gib/1}
            threshold={@card.box.memory_threshold}
          />
        </div>
      </div>

      <p id={"#{@id}-summary"} class="border-t border-line px-5 py-2.5 text-xs text-ink-3">
        {Fleet.cores(@card.summary.cpus)} cores · {gib(@card.summary.memory_mb)} GiB · {@card.count} {if @card.count ==
                                                                                                           1,
                                                                                                         do:
                                                                                                           "environment",
                                                                                                         else:
                                                                                                           "environments"} · placement: {@card.box.capacity_policy}<span :if={
          is_number(@card.summary.disk_free_mb)
        }> · {gib(@card.summary.disk_free_mb)} GiB of disk free</span>
      </p>
    </.link>
    """
  end

  # The CPU trend is scaled to its own peak (at least 20%), so a quiet
  # box still shows its shape; the headline carries the absolute value.
  defp cpu_scale(points) do
    peak = points |> Enum.map(& &1.cpu_max) |> Enum.max(fn -> 0 end)
    ForemanWeb.Charts.Geometry.nice_max(max(peak * 1.2, 20))
  end
end
