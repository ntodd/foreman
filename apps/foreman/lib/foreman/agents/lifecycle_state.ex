defmodule Foreman.Agents.LifecycleState do
  @moduledoc """
  VM state confirmed on the current agent connection. The channel owns its
  registry entries, so another connection cannot inherit a stable response.
  """

  alias Foreman.Registry, as: AgentRegistry

  def joined(box_id) do
    Process.put({__MODULE__, box_id}, DateTime.utc_now())
    Process.put({__MODULE__, :inventory, box_id}, :needed)
  end

  # The outbox can replay old snapshots and state transitions before its first
  # fresh report. Only a command issued on this connection identifies a fresh scan.
  def refresh_inventory(box_id, request) do
    key = {__MODULE__, :inventory, box_id}
    now = System.monotonic_time(:second)

    case Process.get(key) do
      nil ->
        :ok

      %{deadline: deadline} when deadline > now ->
        :ok

      _ ->
        with {:ok, %{status: "dispatched", id: id}} <- request.(),
             do: Process.put(key, %{id: id, deadline: now + 120, changed?: false})
    end

    :ok
  end

  # The reporter and the inventory command sample independently. A report
  # received during a scan may describe a change after its sample was taken.
  def accept_observation?(box_id, env_id \\ :all) do
    if invalidate_pending_scan(box_id) == :pending do
      # A buffered report cannot confirm state. It can still contradict a
      # command that already completed on this connection.
      forget_confirmation(box_id, env_id)
      false
    else
      true
    end
  end

  defp forget_confirmation(box_id, :all) do
    for {__MODULE__, ^box_id, _} = key <- Registry.keys(AgentRegistry, self()),
        do: Registry.unregister(AgentRegistry, key)
  end

  defp forget_confirmation(box_id, env_id),
    do: Registry.unregister(AgentRegistry, {__MODULE__, box_id, env_id})

  defp invalidate_pending_scan(box_id) do
    key = {__MODULE__, :inventory, box_id}

    case Process.get(key) do
      nil ->
        :ready

      %{changed?: false} = scan ->
        Process.put(key, %{scan | changed?: true})
        :pending

      _ ->
        :pending
    end
  end

  def inventory_result(box_id, %{op_id: id} = payload) do
    key = {__MODULE__, :inventory, box_id}

    case Process.get(key) do
      %{id: ^id, changed?: true} when payload.status == "ok" ->
        Process.put(key, :needed)
        :rescan

      %{id: ^id} ->
        if reconcile_scan(box_id, payload) == :ok,
          do: Process.delete(key),
          else: Process.put(key, :needed)

        :ok

      _ ->
        :ok
    end
  end

  defp reconcile_scan(box_id, %{status: "ok", result: %{"environments" => entries}})
       when is_list(entries) do
    with true <- Enum.all?(entries, &is_map/1),
         # Raw VM inventory also carries OOM data delivered by a separate report.
         entries = Enum.map(entries, &Map.delete(&1, "oom_killed_at")),
         {:ok, event} <- ForemanProtocol.Event.new("box.inventory", %{environments: entries}) do
      Foreman.Environments.reconcile_inventory(box_id, event.payload.environments)
    end
  end

  defp reconcile_scan(_, _), do: :error

  def result(
        box_id,
        %{status: "succeeded", dispatched_at: %DateTime{} = sent} = op,
        %{id: _} = env
      )
      when op.action in ~w(create start rebuild pull_rebuild restart_all restart_affected stop suspend) do
    # A result in the reconnecting agent's outbox can predate its reboot.
    joined = Process.get({__MODULE__, box_id})

    if is_nil(joined) or not DateTime.before?(sent, joined) do
      invalidate_pending_scan(box_id)
      record(box_id, env.id, env.observed_state)
    end
  end

  def result(_, _, _), do: :ok

  def record(box_id, env_id, state) do
    if match?([{pid, _}] when pid == self(), Registry.lookup(AgentRegistry, {:agent, box_id})) do
      key = {__MODULE__, box_id, env_id}

      case Registry.update_value(AgentRegistry, key, fn _ -> state end) do
        :error -> Registry.register(AgentRegistry, key, state)
        _ -> :ok
      end
    end

    :ok
  end

  def confirmed?(env, state) do
    with [{pid, _}] <- Registry.lookup(AgentRegistry, {:agent, env.box_id}),
         [{^pid, ^state}] <- Registry.lookup(AgentRegistry, {__MODULE__, env.box_id, env.id}) do
      true
    else
      _ -> false
    end
  end
end
