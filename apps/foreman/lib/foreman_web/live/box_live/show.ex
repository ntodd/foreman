defmodule ForemanWeb.BoxLive.Show do
  @moduledoc "One box: capacity by environment, recent box operations and (admins) its policy."
  use ForemanWeb, :live_view

  import ForemanWeb.ForemanComponents

  alias Foreman.{Accounts, Agents, Boxes, Capacity, Environments, Metrics, Operations, Scope}
  alias Foreman.Agents.Releases

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    box = Boxes.get_visible_box!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Foreman.PubSub, "boxes")
      Metrics.subscribe(box.id)
    end

    {:ok,
     socket
     |> assign(:page_title, box.name)
     |> assign(:box, box)
     |> assign(
       :users,
       if(Scope.admin?(socket.assigns.current_scope), do: Accounts.list_users(), else: [])
     )
     |> assign(:range, "1h")
     |> assign(:latest, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if params["range"] in Metrics.ranges(), do: params["range"], else: "1h"
    {:noreply, socket |> assign(:range, range) |> load_metrics()}
  end

  defp load_metrics(socket) do
    %{box: box, range: range} = socket.assigns
    series = Metrics.box_series(box.id, range)

    socket
    |> assign(:series, series)
    |> assign(:env_series, Metrics.env_series(box.id, range))
    |> assign(:fetched_at, series.until)
  end

  # Re-reads the series once a new bucket's worth of samples has arrived:
  # a 7-day range has 40-minute buckets, so redrawing it every 5 seconds
  # would re-run a week of aggregates for nothing.
  defp maybe_load_metrics(socket, now) do
    if now - socket.assigns.fetched_at >= socket.assigns.series.step,
      do: load_metrics(socket),
      else: socket
  end

  defp load(socket) do
    box = Boxes.get_box!(socket.assigns.box.id)
    envs = Environments.live_for_box(box.id)

    socket
    |> assign(:box, box)
    |> assign(:online, Boxes.online?(box.id))
    |> assign(:envs, envs)
    |> assign(:summary, Capacity.box_summary(box, envs))
    |> assign(
      :ops,
      Operations.list_for_box(box.id, 10) |> Enum.filter(&is_nil(&1.environment_id))
    )
    |> assign(:orphans, Environments.orphans(box.id))
    |> assign(:form, to_form(form_params(box), as: :box))
    |> assign(:target_version, Releases.target_version(box))
    |> assign(:fleet_version, box.arch && Releases.fleet_version(box.arch))
  end

  defp form_params(box) do
    %{
      "capacity_policy" => box.capacity_policy,
      "contention_threshold" => box.contention_threshold,
      "owner_user_id" => box.owner_user_id,
      "shared_user_ids" => box.shared_user_ids,
      "desired_agent_version" => box.desired_agent_version
    }
  end

  @impl true
  def handle_event("save", %{"box" => params}, socket) do
    params = Map.put_new(params, "shared_user_ids", [])

    case Boxes.update_box(
           socket.assigns.current_scope,
           socket.assigns.box,
           Map.put(params, "name", socket.assigns.box.name)
         ) do
      {:ok, _box} ->
        {:noreply, socket |> put_flash(:info, "Saved.") |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(%{cs | action: :update}, as: :box))}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("run", %{"type" => type}, socket)
      when type in ["box.inventory", "box.stats", "box.gc", "box.restart"] do
    box = socket.assigns.box

    case Agents.run_box_command(socket.assigns.current_scope, box, type) do
      {:ok, _op} when type == "box.restart" ->
        {:noreply,
         socket
         |> put_flash(:info, "Rebooting #{box.name}. It'll be back once its agent rejoins.")
         |> load()}

      {:ok, _op} ->
        {:noreply, socket |> put_flash(:info, "Sent to #{box.name}.") |> load()}

      {:error, :cannot_restart} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{box.name}'s agent can't reboot it; run its install command again."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Only admins can do that.")}
    end
  end

  def handle_event("retry_agent_update", _params, socket) do
    case Boxes.retry_agent_update(socket.assigns.current_scope, socket.assigns.box) do
      {:ok, box} ->
        {:noreply, socket |> put_flash(:info, "Sending #{box.name} the agent again.") |> load()}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", _params, socket) do
    case Boxes.revoke(socket.assigns.current_scope, socket.assigns.box) do
      {:ok, box} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Revoked #{box.name}. Its agent is disconnected and can't reconnect."
         )
         |> push_navigate(to: ~p"/boxes")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:box_metrics, _box_id, point}, socket) do
    {:noreply, socket |> assign(:latest, point) |> maybe_load_metrics(point.at)}
  end

  # box.stats also stores environment samples; they show up with the next
  # bucket, like the box's own.
  def handle_info({:box_stats, box_id}, %{assigns: %{box: %{id: box_id}}} = socket),
    do: {:noreply, socket |> load() |> maybe_load_metrics(System.system_time(:second))}

  def handle_info({:box_stats, _other}, socket), do: {:noreply, socket}
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
      <:breadcrumb navigate={~p"/boxes"}>Boxes</:breadcrumb>
      <:breadcrumb>{@box.name}</:breadcrumb>

      <.header>
        {@box.name}
        <:subtitle>
          {@box.hostname || "Never connected"}<span :if={@box.arch}> · {@box.arch}</span><span :if={
            @box.agent_version
          }> · {agent_label(@box, @target_version)}</span>
        </:subtitle>
        <:actions>
          <.badge :if={@summary.contention} color="amber">Contention</.badge>
          <.box_status online={@online} revoked={@box.revoked_at != nil} />
        </:actions>
      </.header>

      <.box_policy_alert box={@box} />
      <.box_firewall_alert box={@box} />
      <.box_reboot_alert box={@box} can_reboot={Scope.admin?(@current_scope) and @online} />

      <.callout
        :if={@box.failed_agent_version && @box.failed_agent_version == @target_version}
        kind="warning"
        id="agent-update-failed"
      >
        <p class="font-medium">
          Agent {@box.failed_agent_version} didn't come up on this box twice, so it isn't sent again.
        </p>
        <p class="mt-0.5">
          The box went back to {@box.agent_version || "its previous agent"}. Its journal (<code>journalctl -u foreman-agent</code>) says why.
        </p>
        <:actions :if={Scope.admin?(@current_scope)}>
          <.button size="sm" phx-click="retry_agent_update">Retry</.button>
        </:actions>
      </.callout>

      <section id="usage" class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <nav id="range-picker" class="segmented" aria-label="Time range">
            <.link
              :for={range <- Metrics.ranges()}
              patch={~p"/boxes/#{@box.id}?range=#{range}"}
              aria-current={to_string(range == @range)}
            >{range}</.link>
          </nav>
          <p class="flex items-center gap-2 text-xs text-ink-3">
            <span class={[
              "size-1.5 rounded-full",
              if(@online, do: "bg-success motion-safe:animate-pulse", else: "bg-line-strong")
            ]} />
            {if @online, do: "Live, every 5 seconds", else: "Box offline"}
          </p>
        </div>
        <ForemanWeb.BoxCharts.usage box={@box} series={@series} envs={@env_series} latest={@latest} />
      </section>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div class="min-w-0 space-y-6">
          <.panel title="Capacity">
            <:subtitle>
              Provisioned counts each running environment's limits, else its hostRequirements, else its 15-minute average.
            </:subtitle>
            <div class="grid gap-4 sm:grid-cols-2">
              <.capacity_bar
                label="CPU used"
                value={@summary.used_cpus}
                max={@summary.cpus}
                unit=" cores"
                threshold={@box.contention_threshold}
              />
              <.capacity_bar
                label="CPU provisioned"
                value={@summary.provisioned_cpus}
                max={@summary.cpus}
                unit=" cores"
                threshold={@box.contention_threshold}
              />
              <.capacity_bar
                label="Memory used"
                value={@summary.used_memory_mb}
                max={@summary.memory_mb}
                unit=" GiB"
                format={&gib/1}
                threshold={@box.contention_threshold}
              />
              <.capacity_bar
                label="Memory provisioned"
                value={@summary.provisioned_memory_mb}
                max={@summary.memory_mb}
                unit=" GiB"
                format={&gib/1}
                threshold={@box.contention_threshold}
              />
              <.capacity_bar
                :if={@summary.disk_mb}
                label="Disk used"
                value={@summary.disk_mb - (@summary.disk_free_mb || 0)}
                max={@summary.disk_mb}
                unit=" GiB"
                format={&gib/1}
                threshold={0.9}
              />
            </div>
          </.panel>

          <.panel title="Environments" padded={false}>
            <div :if={@envs != []} class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead class="border-b border-line text-left text-xs text-ink-3">
                  <tr>
                    <th class="px-5 py-2 font-medium">Environment</th>
                    <th class="px-3 py-2 font-medium">State</th>
                    <th class="px-3 py-2 text-right font-medium">CPUs</th>
                    <th class="px-3 py-2 text-right font-medium">Memory</th>
                    <th class="hidden px-5 py-2 font-medium sm:table-cell">Counted from</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-line">
                  <tr :for={env <- @envs}>
                    <td class="whitespace-nowrap px-5 py-2.5">
                      <.link
                        navigate={~p"/environments/#{env.id}"}
                        class="font-mono font-medium text-ink hover:text-accent-ink"
                      >{env.slug}</.link>
                    </td>
                    <td class="px-3 py-2.5"><.state_badge state={env.observed_state} size="sm" /></td>
                    <% p = Capacity.provisioned(env, env.repo) %>
                    <td class="px-3 py-2.5 text-right tabular-nums">
                      {Float.round(p.cpus * 1.0, 1)}
                    </td>
                    <td class="whitespace-nowrap px-3 py-2.5 text-right tabular-nums">
                      {gib(p.memory_mb)} GiB
                    </td>
                    <td class="hidden px-5 py-2.5 text-xs text-ink-2 sm:table-cell">
                      {source(p.source)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={@envs == []} class="px-5 py-6 text-sm text-ink-3">No environments on this box.</p>
          </.panel>

          <.callout :if={@orphans != []} kind="warning" id="orphans">
            This box has environments Foreman has no record of: {Enum.join(@orphans, ", ")}. They keep running; remove them on the box with docker compose down if they're not wanted.
          </.callout>

          <.panel :if={Scope.admin?(@current_scope)} title="Box operations" id="box-operations">
            <:actions>
              <.button
                size="sm"
                variant="ghost"
                phx-click="run"
                phx-value-type="box.inventory"
                disabled={not @online}
              >Refresh</.button>
              <.button
                size="sm"
                variant="ghost"
                phx-click="run"
                phx-value-type="box.gc"
                disabled={not @online}
                data-confirm="Prune dangling images, old build cache and unused anonymous volumes on this box?"
              >Prune</.button>
              <.button
                :if={@box.can_restart}
                size="sm"
                variant="ghost"
                phx-click="run"
                phx-value-type="box.restart"
                disabled={not @online}
                data-confirm={"Reboot #{@box.name}? Its environments stop, and come back up once it rejoins."}
              >Reboot</.button>
            </:actions>
            <ul :if={@ops != []} class="-m-5 divide-y divide-line">
              <li :for={op <- @ops} class="flex items-center justify-between gap-3 px-5 py-2.5">
                <span class="text-sm text-ink">{action_label(op.action)}</span>
                <span class="flex items-center gap-3">
                  <span :if={op.error} class="max-w-xs truncate text-xs text-danger">{op.error}</span>
                  <.op_status status={op.status} />
                </span>
              </li>
            </ul>
            <p :if={@ops == []} class="text-sm text-ink-3">None yet.</p>
          </.panel>
        </div>

        <aside class="space-y-6">
          <.panel title="Settings">
            <%= if Scope.admin?(@current_scope) do %>
              <.form for={@form} id="box-settings" phx-submit="save" class="space-y-4">
                <.input
                  field={@form[:capacity_policy]}
                  type="select"
                  label="Past capacity"
                  options={[
                    {"Allow, and show contention", "allow"},
                    {"Ask to confirm", "warn"},
                    {"Refuse", "refuse"}
                  ]}
                />
                <.input
                  field={@form[:contention_threshold]}
                  type="number"
                  step="0.05"
                  min="0.1"
                  label="Contention threshold (fraction of capacity)"
                />
                <.input
                  field={@form[:owner_user_id]}
                  type="select"
                  label="Owner"
                  options={Enum.map(@users, &{&1.login, &1.id})}
                />
                <fieldset>
                  <legend class="label">Shared with</legend>
                  <input type="hidden" name="box[shared_user_ids][]" value="" />
                  <div class="space-y-2">
                    <label
                      :for={user <- Enum.reject(@users, &(&1.id == @box.owner_user_id))}
                      class="flex items-center gap-2 text-sm text-ink"
                    >
                      <input
                        type="checkbox"
                        class="checkbox"
                        name="box[shared_user_ids][]"
                        value={user.id}
                        checked={user.id in @box.shared_user_ids}
                      />
                      {user.login}
                    </label>
                  </div>
                  <p
                    :if={Enum.all?(@users, &(&1.id == @box.owner_user_id))}
                    class="text-xs text-ink-3"
                  >
                    Nobody else has signed in yet.
                  </p>
                  <p class="mt-1.5 text-xs text-ink-3">
                    People it's shared with can run environments here. Anyone with Docker on a box can read every environment's secrets on it.
                  </p>
                </fieldset>
                <.input
                  field={@form[:desired_agent_version]}
                  label="Pin the agent version"
                  placeholder={
                    if @fleet_version,
                      do: "Follow this control plane (#{@fleet_version})",
                      else: "Follow this control plane"
                  }
                />
                <.button type="submit" size="sm">Save</.button>
              </.form>
            <% else %>
              <dl class="space-y-2.5">
                <.fact term="Past capacity">{@box.capacity_policy}</.fact>
                <.fact term="Threshold">{round(@box.contention_threshold * 100)}%</.fact>
              </dl>
            <% end %>
          </.panel>

          <.panel :if={Scope.admin?(@current_scope)} title="Danger zone">
            <p class="text-sm text-ink-2">
              Revoking deletes the agent's key and drops its connection. Its environments stay on the box until you remove them.
            </p>
            <.button
              variant="danger_outline"
              size="sm"
              class="mt-3"
              phx-click="revoke"
              data-confirm={"Revoke #{@box.name}?"}
            >Revoke box</.button>
          </.panel>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp source(:limits), do: "limits"
  defp source(:host_requirements), do: "hostRequirements"
  defp source(:observed), do: "observed average"
  defp source(_), do: "not measured yet"

  defp agent_label(box, target) do
    if target in [nil, box.agent_version, box.failed_agent_version],
      do: "agent #{box.agent_version}",
      else: "agent #{box.agent_version}, updating to #{target}"
  end
end
