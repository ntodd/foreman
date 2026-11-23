defmodule Foreman.Agents.LifecycleState do
  @moduledoc """
  VM state confirmed on the current agent connection. The channel owns its
  registry entries, so another connection cannot inherit a stable response.
  """

  alias Foreman.Registry, as: AgentRegistry

  def joined(box_id), do: Process.put({__MODULE__, box_id}, DateTime.utc_now())

  def result(box_id, %{status: "succeeded", dispatched_at: %DateTime{} = sent} = op, env)
      when op.action in ~w(create start rebuild pull_rebuild restart_all restart_affected stop suspend) do
    # A result in the reconnecting agent's outbox can predate its reboot.
    joined = Process.get({__MODULE__, box_id})

    if is_nil(joined) or not DateTime.before?(sent, joined),
      do: record(box_id, env.id, env.observed_state)
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
