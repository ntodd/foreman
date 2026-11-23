defmodule ForemanWeb.ForemanComponents do
  @moduledoc "Components for Foreman's own concepts: environment states, boxes, capacity, commands."
  use Phoenix.Component
  use ForemanWeb, :verified_routes

  import ForemanWeb.CoreComponents

  def fresh_clone_notice do
    "Setup will use a fresh clone. Updated agents save the previous workspace under /mnt/foreman-recovery. On older agents, copy your changes before continuing."
  end

  @doc "An environment's observed state as a badge, pulsing while work is in flight."
  attr :state, :string, required: true
  attr :size, :string, default: "md"

  def state_badge(assigns) do
    ~H"""
    <.badge color={state_color(@state)} dot pulse={busy?(@state)} size={@size} data-state={@state}>
      {state_label(@state)}
    </.badge>
    """
  end

  def busy?(state), do: state in ~w(pending creating starting stopping suspending destroying)

  @doc """
  Marks an environment that ran out of memory in the last day, beside its
  state. Its page says what happened.
  """
  attr :env, :map, required: true

  def oom_badge(assigns) do
    ~H"""
    <.badge
      :if={Foreman.Environments.Environment.recent_oom?(@env)}
      color="rose"
      size="sm"
      data-role="oom"
    >
      Out of memory
    </.badge>
    """
  end

  defp state_color("running"), do: "emerald"
  defp state_color("partial"), do: "amber"
  defp state_color("error"), do: "rose"
  defp state_color("missing"), do: "rose"

  defp state_color(state)
       when state in ~w(pending creating starting stopping suspending destroying),
       do: "brand"

  defp state_color(_), do: "zinc"

  def state_label("pending"), do: "Queued"
  def state_label("creating"), do: "Creating"
  def state_label("starting"), do: "Starting"
  def state_label("stopping"), do: "Stopping"
  def state_label("suspending"), do: "Suspending"
  def state_label("suspended"), do: "Suspended"
  def state_label("destroying"), do: "Destroying"
  def state_label("running"), do: "Running"
  def state_label("stopped"), do: "Stopped"
  def state_label("partial"), do: "Partly running"
  def state_label("missing"), do: "Missing"
  def state_label("error"), do: "Error"
  def state_label("destroyed"), do: "Destroyed"
  def state_label(other), do: other

  @doc "Online/offline for a box."
  attr :online, :boolean, required: true
  attr :revoked, :boolean, default: false

  def box_status(assigns) do
    ~H"""
    <.badge :if={@revoked} color="rose" dot>Revoked</.badge>
    <.badge :if={not @revoked and @online} color="emerald" dot>Online</.badge>
    <.badge :if={not @revoked and not @online} color="zinc" dot>Offline</.badge>
    """
  end

  @doc "The chip on a box card when the box can't run environments."
  attr :box, :map, required: true

  def box_vm_badge(assigns) do
    assigns = assign(assigns, :problem, Foreman.Boxes.vm_problem(assigns.box))

    ~H"""
    <.badge :if={@problem} color="rose" size="sm" data-role="vm-alert">
      {case @problem do
        {:agent, _} -> "Agent too old"
        {:vm, _} -> "Can't run environments"
      end}
    </.badge>
    """
  end

  @doc """
  The box page's alert for a box that can't run environments: an agent
  from before environment VMs, or one that says it can't run them.
  """
  attr :box, :map, required: true

  def box_vm_alert(assigns) do
    assigns =
      assigns
      |> assign(:problem, Foreman.Boxes.vm_problem(assigns.box))
      |> assign(:command, Foreman.Boxes.reinstall_command(assigns.box))

    ~H"""
    <.callout :if={@problem} kind="danger" id="box-vm-alert">
      <p class="text-[15px] font-semibold">This box can't run environments</p>
      <p :if={match?({:agent, _}, @problem)} class="mt-1">
        Its agent ({elem(@problem, 1)}) ran environments on the box's shared Docker, which this Foreman no longer does: every environment runs in a VM of its own now. Foreman refuses the agent until the install script runs again, which sets the box up for VMs: <span class="font-mono break-all">{@command}</span>. Environments made before then can't start; push their work, then destroy and recreate them.
      </p>
      <p :if={match?({:vm, _}, @problem)} class="mt-1">
        {String.capitalize(elem(@problem, 1))}.
      </p>
    </.callout>
    """
  end

  @doc "The chip on a box card when the box's firewall isn't keeping environments off the tailnet."
  attr :box, :map, required: true

  def box_firewall_badge(assigns) do
    assigns = assign(assigns, :problem, Foreman.Boxes.firewall_problem(assigns.box))

    ~H"""
    <.badge
      :if={@problem in [:missing, :outdated]}
      color={if @problem == :missing, do: "rose", else: "amber"}
      size="sm"
      data-role="firewall-alert"
    >
      {if @problem == :missing, do: "Firewall unconfirmed", else: "Firewall rules differ"}
    </.badge>
    """
  end

  @doc "The box page's alert for a box whose firewall isn't loaded, is out of date, or leaves builds out."
  attr :box, :map, required: true

  def box_firewall_alert(assigns) do
    assigns =
      assigns
      |> assign(:problem, Foreman.Boxes.firewall_problem(assigns.box))
      |> assign(:command, Foreman.Boxes.reinstall_command(assigns.box))

    ~H"""
    <.callout
      :if={@problem}
      kind={if @problem == :missing, do: "danger", else: "warning"}
      id="box-firewall-alert"
      class={@problem == :missing && "border-2"}
    >
      <p class="text-[15px] font-semibold">
        {case @problem do
          :missing -> "Foreman can't confirm this box's firewall is loaded"
          :outdated -> "This box's firewall rules differ from its agent's"
          :default_bridge -> "Image builds on this box can reach the tailnet as this box"
        end}
      </p>
      <p class="mt-1">
        {case @problem do
          :missing ->
            "Without it, code in this box's environments can reach the tailnet as this box, with its tags and grants, not just tag:foreman-env's."

          :outdated ->
            "The rules loaded on the box differ from the ones its agent ships with. Agents update themselves, but the rules only change when the install script runs."

          :default_bridge ->
            "It was installed with --default-bridge-reaches-tailnet, which leaves Docker's default bridge, where image builds run, unfiltered."
        end}
      </p>
      <p :if={@problem != :default_bridge} class="mt-2 text-xs">
        Run the install command on the box again. An enrolled box needs no token, and this one keeps its policy and default bridge setting: <span class="font-mono break-all">{@command}</span>. If the firewall is installed,
        <span class="font-mono">systemctl status foreman-firewall</span>
        on the box says what's wrong.
      </p>
    </.callout>
    """
  end

  @doc "The chip on a box card when the box needs a reboot."
  attr :box, :map, required: true

  def box_reboot_badge(assigns) do
    assigns = assign(assigns, :needed, Foreman.Boxes.reboot_needed(assigns.box))

    ~H"""
    <.badge :if={@needed} color="amber" size="sm" data-role="reboot-alert">
      Reboot required
    </.badge>
    """
  end

  @doc """
  The box page's alert for a box that needs a reboot, with what asked for
  it, and (`can_reboot`: an admin, the box online) a button that reboots
  it when its agent can.
  """
  attr :box, :map, required: true
  attr :can_reboot, :boolean, default: false

  def box_reboot_alert(assigns) do
    assigns = assign(assigns, :needed, Foreman.Boxes.reboot_needed(assigns.box))

    ~H"""
    <.callout :if={@needed} kind="warning" id="box-reboot-alert">
      <p class="text-[15px] font-semibold">This box needs a reboot</p>
      <p class="mt-1">
        Updates installed on the box only take effect once it restarts. Its environments stop while it's down, and come back up on their own once the agent rejoins.
      </p>
      <p :if={@box.livepatch} class="mt-1">
        An enabled kernel livepatch (Livepatch or kpatch) was detected. That doesn't establish that the pending updates are covered, so the reboot stays required.
      </p>
      <p :if={@box.reboot_packages != []} class="mt-2 text-xs">
        For: <span class="font-mono break-all">{Enum.join(@box.reboot_packages, ", ")}</span>
      </p>
      <p :if={@can_reboot and not @box.can_restart} class="mt-2 text-xs">
        To reboot it from here, run the install command on the box again; it sets up what Foreman reboots it with.
      </p>
      <:actions :if={@can_reboot and @box.can_restart}>
        <.button
          size="sm"
          phx-click="run"
          phx-value-type="box.restart"
          data-confirm={"Reboot #{@box.name}? Its environments stop, and come back up once it rejoins."}
        >Reboot now</.button>
      </:actions>
    </.callout>
    """
  end

  @doc """
  A labelled capacity bar: used (or provisioned) of total. With `used`,
  the bar also carries what's in use: it shows the larger of the two and
  takes the color of whichever is further past its threshold, usage being
  held to `Foreman.Capacity.used_threshold/1`.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :used, :any, default: nil
  attr :max, :any, required: true
  attr :unit, :string, default: ""
  attr :threshold, :float, default: 0.9
  attr :format, :any, default: nil

  def capacity_bar(assigns) do
    max = if is_number(assigns.max) and assigns.max > 0, do: assigns.max, else: nil
    value = assigns.value || 0
    shown = if assigns.used, do: Kernel.max(value, assigns.used), else: assigns.value
    ratio = if max, do: (shown || 0) / max, else: 0

    level =
      if max do
        provisioned = bar_level(value / max, assigns.threshold)

        if assigns.used,
          do:
            Kernel.max(
              provisioned,
              bar_level(assigns.used / max, Foreman.Capacity.used_threshold(assigns.threshold))
            ),
          else: provisioned
      end

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:ratio, ratio)
      |> assign(:level, level)
      |> assign(:max_value, max && round(max * 100))
      |> assign(:bar_value, max && round(min(shown || 0, max) * 100))

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-baseline justify-between gap-2 text-xs">
        <span class="text-ink-2">{@label}</span>
        <span class="tabular-nums text-ink-3">
          {fmt(@shown, @format)}<span :if={@max_value}> / {fmt(@max, @format)}</span>{@unit}
        </span>
      </div>
      <progress
        :if={@max_value}
        class={["bar", bar_class(@level)]}
        value={@bar_value}
        max={@max_value}
        aria-label={@label}
      >
        {round(@ratio * 100)}%
      </progress>
    </div>
    """
  end

  # Amber past the threshold or 100%, whichever comes first, and red past
  # both: a box set to overcommit is amber while it does and red past
  # what it allows. 0 is fine, 1 amber, 2 red.
  defp bar_level(ratio, threshold) do
    cond do
      ratio > max(threshold, 1) -> 2
      ratio > min(threshold, 1) -> 1
      true -> 0
    end
  end

  defp bar_class(2), do: "bar-danger"
  defp bar_class(1), do: "bar-warning"
  defp bar_class(_), do: nil

  defp fmt(nil, _), do: "0"
  defp fmt(value, fun) when is_function(fun, 1), do: fun.(value)

  defp fmt(value, _) when is_float(value),
    do: :erlang.float_to_binary(Float.round(value, 1), [:short])

  defp fmt(value, _), do: to_string(value)

  # One decimal below 100 GiB, whole numbers above ("1758", not "1.8e3").
  def gib(mb) when is_number(mb) and mb >= 100 * 1024, do: Integer.to_string(round(mb / 1024))
  def gib(mb) when is_number(mb), do: :erlang.float_to_binary(mb / 1024, decimals: 1)
  def gib(_), do: "0"

  @doc "A shell command with a copy button."
  attr :id, :string, required: true
  attr :command, :string, required: true
  attr :label, :string, default: nil

  def command(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <p :if={@label} class="text-xs font-medium text-ink-2">{@label}</p>
      <div class="flex items-stretch gap-2">
        <code id={@id} class="command min-w-0 flex-1 text-ink">{@command}</code>
        <button
          type="button"
          id={"#{@id}-copy"}
          data-copy={@command}
          class="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-line-strong bg-canvas px-3 text-xs font-medium text-ink-2 shadow-control transition-colors hover:bg-subtle hover:text-ink"
        >
          <.icon name="hero-clipboard-document-micro" class="size-3.5" />
          <span data-copy-label>Copy</span>
        </button>
      </div>
    </div>
    """
  end

  @doc "A fleet metric with a value, an optional breakdown, and a note."
  attr :id, :string, default: nil
  attr :value_id, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :detail, doc: "a breakdown of the value, under it"
  slot :note

  def stat_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex min-w-0 flex-col rounded-xl border border-line bg-raised px-5 py-4 shadow-xs"
    >
      <div class="flex items-center justify-between gap-2">
        <p class="text-xs font-medium text-ink-2">{@label}</p>
        <.icon name={@icon} class="size-4 shrink-0 text-accent-ink" />
      </div>
      <p id={@value_id} class="mt-2 text-2xl font-semibold leading-none tabular-nums text-ink">
        {render_slot(@inner_block)}
      </p>
      <p :if={@detail != []} class="mt-2 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-ink-2">
        {render_slot(@detail)}
      </p>
      <p :if={@note != []} class="mt-auto pt-2 text-xs text-ink-3">{render_slot(@note)}</p>
    </div>
    """
  end

  @doc "A titled panel, the basic surface for page sections."
  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  attr :split, :boolean,
    default: false,
    doc: "Place the heading beside a short form on wide screens."

  attr :padded, :boolean, default: true
  slot :actions
  slot :subtitle
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "min-w-0 rounded-xl border border-line bg-raised shadow-xs",
        @split && "xl:grid xl:grid-cols-[minmax(14rem,1fr)_minmax(0,3fr)]",
        @class
      ]}
    >
      <header
        :if={@title}
        class={[
          "flex flex-wrap items-start justify-between gap-x-4 gap-y-2 rounded-t-xl border-b border-line bg-muted/30 px-5 py-3.5",
          @split && "xl:items-center xl:rounded-l-xl xl:rounded-tr-none xl:border-r xl:border-b-0"
        ]}
      >
        <%!-- Actions drop below the title when there's no room for both. --%>
        <div class="min-w-0 flex-1 basis-48">
          <h2 class="text-sm font-semibold text-ink">{@title}</h2>
          <p :if={@subtitle != []} class="mt-0.5 text-xs text-ink-2">{render_slot(@subtitle)}</p>
        </div>
        <div :if={@actions != []} class="flex max-w-full flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class={@padded && "p-5"}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc "A notice strip: info, warning or danger."
  attr :kind, :string, default: "info", values: ~w(info warning danger)
  attr :icon, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :actions

  def callout(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col gap-3 rounded-xl border px-4 py-3 text-sm sm:flex-row sm:items-center",
        @kind == "info" && "border-line bg-subtle text-ink-2",
        @kind == "warning" && "border-warning/30 bg-warning-soft text-warning",
        @kind == "danger" && "border-danger/30 bg-danger-soft text-danger",
        @class
      ]}
    >
      <div class="flex flex-1 items-start gap-2.5">
        <.icon name={@icon || callout_icon(@kind)} class="mt-0.5 size-4 shrink-0" />
        <div class="min-w-0 flex-1">{render_slot(@inner_block)}</div>
      </div>
      <div :if={@actions != []} class="flex max-w-full flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  defp callout_icon("info"), do: "hero-information-circle-mini"
  defp callout_icon("warning"), do: "hero-exclamation-triangle-mini"
  defp callout_icon("danger"), do: "hero-x-circle-mini"

  @doc "An operation's status as a small icon and label."
  attr :status, :string, required: true

  def op_status(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-xs font-medium", op_color(@status)]}>
      <.icon
        name={op_icon(@status)}
        class={["size-4", @status in ~w(dispatched running) && "motion-safe:animate-spin"]}
      />
      {op_label(@status)}
    </span>
    """
  end

  defp op_icon("succeeded"), do: "hero-check-circle-mini"
  defp op_icon("failed"), do: "hero-x-circle-mini"
  defp op_icon("cancelled"), do: "hero-minus-circle-mini"
  defp op_icon("queued"), do: "hero-clock-mini"
  defp op_icon(_), do: "hero-arrow-path-mini"

  defp op_color("succeeded"), do: "text-success"
  defp op_color("failed"), do: "text-danger"
  defp op_color("queued"), do: "text-ink-3"
  defp op_color("cancelled"), do: "text-ink-3"
  defp op_color(_), do: "text-accent-ink"

  defp op_label("dispatched"), do: "Sent"
  defp op_label(status), do: String.capitalize(status)

  @doc "A human name for an operation's action."
  def action_label("create"), do: "Create"
  def action_label("rebuild"), do: "Rebuild"
  def action_label("pull_rebuild"), do: "Pull and rebuild"
  def action_label("start"), do: "Start"
  def action_label("stop"), do: "Stop"
  def action_label("destroy"), do: "Destroy"
  def action_label("restart_affected"), do: "Restart affected services"
  def action_label("restart_all"), do: "Restart everything"
  def action_label("secrets_write"), do: "Update secrets"
  def action_label("git_status"), do: "Check git status"
  def action_label("connect"), do: "Connect hook action"
  def action_label("logs"), do: "Fetch container logs"
  def action_label("box.inventory"), do: "Refresh inventory"
  def action_label("box.stats"), do: "Refresh stats"
  def action_label("box.gc"), do: "Prune images and caches"
  def action_label("box.restart"), do: "Reboot"
  def action_label("box.prebuild"), do: "Build a prebuild"
  def action_label("box.prebuild.delete"), do: "Delete a prebuild"
  def action_label("agent.update"), do: "Update agent"
  def action_label("op.cancel"), do: "Cancel an operation"
  def action_label(other), do: other
  attr :warning, :map, required: true

  def start_warning(assigns) do
    label = %{
      "start" => "Start",
      "retry" => "Retry",
      "rebuild" => "Rebuild",
      "pull_rebuild" => "Pull and rebuild"
    }

    assigns = assign(assigns, :label, Map.fetch!(label, assigns.warning.action))

    ~H"""
    <.callout kind="warning" id="start-warning">
      <p class="font-medium">{@label} {@warning.slug}?</p>
      <p>{@warning.message}</p>
      <:actions>
        <.button size="sm" phx-click="confirm_start">{@label} anyway</.button>
        <.button size="sm" variant="ghost" phx-click="dismiss_start">Cancel</.button>
      </:actions>
    </.callout>
    """
  end
end
