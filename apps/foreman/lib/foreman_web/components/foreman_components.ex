defmodule ForemanWeb.ForemanComponents do
  @moduledoc "Components for Foreman's own concepts: environment states, boxes, capacity, commands."
  use Phoenix.Component
  use ForemanWeb, :verified_routes

  import ForemanWeb.CoreComponents

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

  def busy?(state), do: state in ~w(pending creating starting stopping destroying)

  defp state_color("running"), do: "emerald"
  defp state_color("partial"), do: "amber"
  defp state_color("error"), do: "rose"
  defp state_color("missing"), do: "rose"

  defp state_color(state) when state in ~w(pending creating starting stopping destroying),
    do: "brand"

  defp state_color(_), do: "zinc"

  def state_label("pending"), do: "Queued"
  def state_label("creating"), do: "Creating"
  def state_label("starting"), do: "Starting"
  def state_label("stopping"), do: "Stopping"
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

  @doc """
  The chip on a box card when the box's agent accepts more than the
  default policy. Privileged is called out by name.
  """
  attr :box, :map, required: true

  def box_policy_badge(assigns) do
    assigns = assign(assigns, :exceptions, Foreman.Boxes.policy_exceptions(assigns.box))

    ~H"""
    <.badge :if={@exceptions != []} color="rose" size="sm" data-role="policy-alert">
      {if Enum.any?(@exceptions, &(&1.rule == "privileged")),
        do: "Privileged allowed",
        else: "Policy relaxed"}
    </.badge>
    """
  end

  @doc "The box page's alert for a box that accepts more than the default policy."
  attr :box, :map, required: true

  def box_policy_alert(assigns) do
    exceptions = Foreman.Boxes.policy_exceptions(assigns.box)

    assigns =
      assigns
      |> assign(:exceptions, exceptions)
      |> assign(:privileged, Enum.any?(exceptions, &(&1.rule == "privileged")))

    ~H"""
    <.callout :if={@exceptions != []} kind="danger" id="box-policy-alert" class="border-2">
      <p class="text-[15px] font-semibold">
        {if @privileged,
          do: "Environments on this box can run privileged",
          else: "This box accepts more than the default policy"}
      </p>
      <p :if={@privileged} class="mt-1">
        Privileged code is root on the box: it can read every environment's secrets, the agent's key and anything else on the machine. Only allow it on a box that holds nothing else you care about.
      </p>
      <ul class="mt-2 list-disc space-y-0.5 pl-5">
        <li :for={e <- @exceptions}>
          {if e.action == "allow", do: "Allowed", else: "Allowed with a warning"}: {e.label}
        </li>
      </ul>
      <p class="mt-2 text-xs">
        Set by <span class="font-mono">FOREMAN_POLICY</span>
        in <span class="font-mono">/etc/foreman-agent/agent.env</span>
        on the box. Remove it and restart the agent to refuse these again.
      </p>
    </.callout>
    """
  end

  @doc "A labelled capacity bar: used (or provisioned) of total."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :max, :any, required: true
  attr :unit, :string, default: ""
  attr :threshold, :float, default: 0.9
  attr :format, :any, default: nil

  def capacity_bar(assigns) do
    max = if is_number(assigns.max) and assigns.max > 0, do: assigns.max, else: nil
    ratio = if max, do: (assigns.value || 0) / max, else: 0

    assigns =
      assigns
      |> assign(:ratio, ratio)
      |> assign(:max_value, max && round(max * 100))
      |> assign(:bar_value, max && round(min(assigns.value || 0, max) * 100))

    ~H"""
    <div class="space-y-1.5">
      <div class="flex items-baseline justify-between gap-2 text-xs">
        <span class="text-ink-2">{@label}</span>
        <span class="tabular-nums text-ink-3">
          {fmt(@value, @format)}<span :if={@max_value}> / {fmt(@max, @format)}</span>{@unit}
        </span>
      </div>
      <progress
        :if={@max_value}
        class={["bar", bar_class(@ratio, @threshold)]}
        value={@bar_value}
        max={@max_value}
        aria-label={@label}
      >
        {round(@ratio * 100)}%
      </progress>
    </div>
    """
  end

  defp bar_class(ratio, threshold) when ratio > 1,
    do: if(threshold < 1, do: "bar-danger", else: "bar-warning")

  defp bar_class(ratio, threshold) when ratio > threshold, do: "bar-warning"
  defp bar_class(_, _), do: nil

  defp fmt(nil, _), do: "0"
  defp fmt(value, fun) when is_function(fun, 1), do: fun.(value)

  defp fmt(value, _) when is_float(value),
    do: :erlang.float_to_binary(Float.round(value, 1), [:short])

  defp fmt(value, _), do: to_string(value)

  def gib(mb) when is_number(mb), do: :erlang.float_to_binary(Float.round(mb / 1024, 1), [:short])
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
          phx-hook="Copy"
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

  @doc "A titled panel, the basic surface for page sections."
  attr :title, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :padded, :boolean, default: true
  slot :actions
  slot :subtitle
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-xl border border-line bg-raised shadow-xs", @class]}>
      <header
        :if={@title}
        class="flex items-start justify-between gap-4 border-b border-line px-5 py-3.5"
      >
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-ink">{@title}</h2>
          <p :if={@subtitle != []} class="mt-0.5 text-xs text-ink-2">{render_slot(@subtitle)}</p>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
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
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
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
  def action_label("start"), do: "Start"
  def action_label("stop"), do: "Stop"
  def action_label("destroy"), do: "Destroy"
  def action_label("restart_affected"), do: "Restart affected services"
  def action_label("restart_all"), do: "Restart everything"
  def action_label("secrets_write"), do: "Update secrets"
  def action_label("git_status"), do: "Check git status"
  def action_label("logs"), do: "Fetch container logs"
  def action_label("box.inventory"), do: "Refresh inventory"
  def action_label("box.stats"), do: "Refresh stats"
  def action_label("box.gc"), do: "Prune images and caches"
  def action_label("agent.update"), do: "Update agent"
  def action_label("op.cancel"), do: "Cancel an operation"
  def action_label(other), do: other
end
