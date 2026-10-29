defmodule Foreman.Agents do
  @moduledoc """
  The link to agents: sending commands to a connected agent's channel and
  handling the events agents send back.

  Each connected agent's channel process registers under
  `{:agent, box_id}`. Events are only accepted for operations and
  environments that belong to the sending box.
  """
  import Ecto.Query

  alias Foreman.{Boxes, Environments, Metrics, Operations, Repo, Scope}
  alias Foreman.Capacity.Tracker
  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation
  alias ForemanProtocol.{Command, Event}

  require Logger

  @doc "Called by the channel process once an agent has joined."
  def register(box_id) do
    case Registry.register(Foreman.Registry, {:agent, box_id}, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, old}} ->
        # A second connection for the same box replaces the first.
        Process.exit(old, :kill)
        Process.sleep(20)
        register(box_id)
    end
  end

  @doc "Sends a command to a box's agent. `{:error, :offline}` if it isn't connected."
  def dispatch(box_id, %Command{} = cmd) do
    case Registry.lookup(Foreman.Registry, {:agent, box_id}) do
      [{pid, _}] ->
        send(pid, {:dispatch, cmd})
        :ok

      [] ->
        {:error, :offline}
    end
  end

  @doc """
  Runs a box-level command (inventory, stats, gc, restart). Returns the
  operation, whose result arrives later.

  A restart reboots the box, and names the boot the agent last reported:
  `{:error, :cannot_restart}` for a box whose agent can't (one before
  protocol 5, or installed before the root unit that does it).
  """
  def run_box_command(%Scope{} = scope, box, "box.restart") do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      not box.can_restart or is_nil(box.boot_id) -> {:error, :cannot_restart}
      true -> send_box_command(scope, box, "box.restart", %{boot_id: box.boot_id})
    end
  end

  def run_box_command(%Scope{} = scope, box, type)
      when type in ["box.inventory", "box.stats", "box.gc"] do
    if Scope.admin?(scope),
      do: send_box_command(scope, box, type, %{}),
      else: {:error, :unauthorized}
  end

  defp send_box_command(scope, box, type, payload) do
    {:ok, cmd} = Command.new(type, payload)

    op =
      Operations.create!(%{
        id: cmd.op_id,
        box_id: box.id,
        user_id: Scope.user_id(scope),
        action: type,
        command: type,
        args:
          if(payload == %{},
            do: nil,
            else: Map.new(payload, &{to_string(elem(&1, 0)), elem(&1, 1)})
          ),
        status: "dispatched",
        dispatched_at: DateTime.utc_now()
      })

    case dispatch(box.id, cmd) do
      :ok ->
        {:ok, op}

      {:error, :offline} ->
        {:ok,
         Operations.mark(op, "failed",
           error: "the box is offline",
           finished_at: DateTime.utc_now()
         )}
    end
  end

  @doc """
  Asks the agent to stop a dispatched or running operation. It kills the
  operation's processes and reports it with the error "cancelled", which
  marks it cancelled. The `op.cancel` command is recorded as a box
  operation of its own, so the agent's result for it is acknowledged.
  """
  def cancel_operation(%Operation{status: status} = target, user_id)
      when status in ["dispatched", "running"] do
    {:ok, cmd} = Command.new("op.cancel", %{target_op_id: target.id})

    op =
      Operations.create!(%{
        id: cmd.op_id,
        box_id: target.box_id,
        user_id: user_id,
        action: "op.cancel",
        command: "op.cancel",
        args: %{"target_op_id" => target.id},
        status: "dispatched",
        dispatched_at: DateTime.utc_now()
      })

    # Recorded before it's sent: a reconnect between the two would otherwise
    # resend the operation itself.
    :ok = Operations.request_cancel(target)

    case dispatch(target.box_id, cmd) do
      :ok ->
        :ok

      {:error, :offline} ->
        :ok = Operations.withdraw_cancel(target)

        Operations.mark(op, "failed",
          error: "the box is offline",
          finished_at: DateTime.utc_now()
        )

        {:error, "The box is offline, so the operation can't be stopped."}
    end
  end

  # -- events --------------------------------------------------------------------

  @doc "Handles one event from `box_id`'s agent. Returns :ok or {:error, reason}."
  def handle_event(box_id, %Event{type: "op.accepted", payload: %{op_id: op_id}}) do
    with :ok <- owns_op(box_id, op_id) do
      Operations.mark_running(op_id)
      :ok
    end
  end

  def handle_event(box_id, %Event{type: "op.log", payload: %{op_id: op_id, data: data}}) do
    with :ok <- owns_op(box_id, op_id), do: Operations.append_log(op_id, data)
  end

  # The operation and its environment's new state are recorded in one
  # transaction: if applying the result raises, neither is, and the
  # agent's redelivery (it keeps results until they're acknowledged)
  # gets another go rather than being ignored as a repeat.
  def handle_event(box_id, %Event{type: "op.result", payload: payload}) do
    case owns_op(box_id, payload.op_id) do
      :ok ->
        {payload, offer} = take_offer(payload)

        case Operations.finish(
               payload.op_id,
               payload.status,
               payload[:result] || %{},
               payload[:error],
               &Environments.record_result/1
             ) do
          {:ok, op, env} ->
            if offer && op.status == "succeeded",
              do: Environments.deliver_offer(op.id, offer)

            Environments.after_result(op, env)

          :already ->
            :ok

          :unknown ->
            :ok
        end

      # Nothing to record it against (pruned, or from another control
      # plane's database). Acknowledged so the agent stops resending it.
      {:error, :unknown_operation} ->
        Logger.warning("box #{box_id} reported a result for unknown operation #{payload.op_id}")
        :ok

      error ->
        error
    end
  end

  def handle_event(box_id, %Event{type: "box.inventory", payload: %{environments: envs}}) do
    Environments.reconcile_inventory(box_id, envs)
  end

  def handle_event(box_id, %Event{type: "box.stats", payload: stats}) do
    slugs = Environments.live_slugs_for_box(box_id)
    stats = %{stats | environments: Map.take(stats.environments, Map.keys(slugs))}

    Tracker.record(box_id, stats)
    Boxes.record_capacity(box_id, stats.capacity)

    Metrics.record_envs(
      box_id,
      Map.new(stats.environments, fn {id, usage} -> {id, Map.put(usage, :slug, slugs[id])} end)
    )
  end

  def handle_event(box_id, %Event{type: "box.ports", payload: %{environments: envs}}) do
    Foreman.Ports.record(box_id, envs)
  end

  def handle_event(box_id, %Event{type: "box.firewall", payload: firewall}) do
    Boxes.record_firewall(box_id, firewall)
  end

  def handle_event(box_id, %Event{type: "box.reboot", payload: reboot}) do
    Boxes.record_reboot(box_id, reboot)
  end

  def handle_event(box_id, %Event{type: "box.metrics", payload: sample}) do
    Metrics.record_box(box_id, sample)
  end

  def handle_event(box_id, %Event{type: "env.state", payload: %{env_id: env_id, state: state}}) do
    Environments.observe(box_id, env_id, state)
  end

  defp owns_op(box_id, op_id) do
    case Repo.one(from o in Operation, where: o.id == ^op_id, select: o.box_id) do
      ^box_id ->
        :ok

      nil ->
        {:error, :unknown_operation}

      _other ->
        Logger.warning("box #{box_id} sent an event for another box's operation #{op_id}")
        {:error, :not_yours}
    end
  end

  # A connect hook's result (`ForemanProtocol.Connect`) is a secret: it's
  # taken out before the operation is recorded, and only broadcast. One
  # that doesn't fit fails the operation without saying what it was.
  defp take_offer(%{result: %{"offer" => offer} = result} = payload) do
    payload = %{payload | result: Map.delete(result, "offer")}

    case ForemanProtocol.Connect.cast_offer(offer) do
      {:ok, offer} ->
        {payload, offer}

      {:error, reason} ->
        error = "the connect hook's result can't be shown: #{reason}"
        {Map.merge(payload, %{status: "error", error: error}), nil}
    end
  end

  defp take_offer(payload), do: {payload, nil}

  @doc """
  Called as an agent joins, before the box counts as online: restarts
  Housekeeping's clock for the environment operations it's about to be
  resent and doesn't have (`in_flight` is what it still has queued or
  running). It lost those in a restart and runs them from the start. The
  ones it kept have been running all along, so they keep their clock, or a
  connection that keeps dropping would keep a hung operation alive.
  """
  def restart_clocks(box_id, in_flight) do
    box_id
    |> Operations.active_for_box()
    |> Enum.filter(&(&1.environment_id && &1.id not in in_flight))
    |> Enum.map(& &1.id)
    |> Operations.restart_clock()
  end

  @doc """
  Called when an agent joins: resend what was in flight and dispatch
  what's queued. Box commands (gc, stats, an update) aren't resent; their
  results usually follow straight after the join, from the agent's
  outbox. Housekeeping fails the ones that never arrive.
  """
  def agent_connected(box) do
    for op <- Operations.active_for_box(box.id),
        op.environment_id,
        do: Environments.Server.resend(op.environment_id, op.id)

    for env_id <- Operations.environments_with_queued(box.id),
        do: Environments.Server.kick(env_id)

    Foreman.Agents.Releases.maybe_update(box)
    :ok
  end

  def env_belongs_to_box?(env_id, box_id) do
    Repo.exists?(from e in Environment, where: e.id == ^env_id and e.box_id == ^box_id)
  end
end
