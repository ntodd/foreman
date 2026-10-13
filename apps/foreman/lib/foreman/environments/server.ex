defmodule Foreman.Environments.Server do
  @moduledoc """
  Sends one environment's operations to its box, one at a time.

  The queue lives in the database (operations with status `queued`), so
  nothing is lost when the control plane restarts; this process only
  serializes dispatch for its environment. It's started on demand and
  stops after a minute idle.

  Operations that were sent but hadn't finished when the agent
  disconnected are resent with the same op_id on reconnect; the agent
  recognises a repeat and won't run it twice.
  """
  use GenServer, restart: :temporary

  alias Foreman.{Agents, Boxes, Environments, Operations, Repo}
  alias Foreman.Environments.{Commands, Environment}

  require Logger

  @idle_timeout 60_000

  # Tests dispatch in the calling process, so they can assert on what was
  # sent without waiting on another process.
  def kick(env_id) do
    if sync?(),
      do: dispatch_next(env_id),
      else: env_id |> ensure_started() |> GenServer.cast(:kick)

    :ok
  end

  def resend(env_id, op_id) do
    if sync?(),
      do: do_resend(env_id, op_id),
      else: env_id |> ensure_started() |> GenServer.cast({:resend, op_id})

    :ok
  end

  defp sync?, do: Application.get_env(:foreman, :sync_dispatch, false)

  defp ensure_started(env_id) do
    name = {:via, Registry, {Foreman.Registry, {:env_server, env_id}}}

    case DynamicSupervisor.start_child(
           Foreman.Environments.Supervisor,
           {__MODULE__, {env_id, name}}
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  def start_link({env_id, name}), do: GenServer.start_link(__MODULE__, env_id, name: name)

  @impl true
  def init(env_id) do
    Logger.metadata(env_id: env_id)
    {:ok, env_id, @idle_timeout}
  end

  @impl true
  def handle_cast(:kick, env_id) do
    dispatch_next(env_id)
    {:noreply, env_id, @idle_timeout}
  end

  def handle_cast({:resend, op_id}, env_id) do
    do_resend(env_id, op_id)
    {:noreply, env_id, @idle_timeout}
  end

  defp do_resend(env_id, op_id) do
    case Operations.get(op_id) do
      %{status: status} = op when status in ["dispatched", "running"] ->
        send_op(op, Repo.get!(Environment, env_id))

      _ ->
        :ok
    end
  end

  @impl true
  def handle_info(:timeout, env_id), do: {:stop, :normal, env_id}

  defp dispatch_next(env_id) do
    env = Repo.get(Environment, env_id)

    cond do
      is_nil(env) -> :ok
      Operations.in_flight(env_id) -> :ok
      not Boxes.online?(env.box_id) -> :ok
      op = Operations.next_queued(env_id) -> dispatch(op, env)
      true -> :ok
    end
  end

  defp dispatch(op, %Environment{destroyed_at: destroyed} = env) when not is_nil(destroyed) do
    Operations.cancel_queued(op)
    dispatch_next(env.id)
  end

  defp dispatch(op, env) do
    case send_op(op, env) do
      :ok ->
        if state = Environments.transitional_state(op.action) do
          Environments.update_env!(env, %{observed_state: state, status_message: nil})
        end

        :ok

      {:error, :offline} ->
        :ok

      {:error, message} ->
        Logger.warning("couldn't send #{op.action} for #{env.slug}: #{message}")
        op = Operations.mark(op, "failed", error: message, finished_at: DateTime.utc_now())
        Environments.apply_result(op)
    end
  end

  # Builds the command fresh (current secrets and token) and sends it.
  defp send_op(op, env) do
    with {:ok, cmd, extra} <- Commands.build(op, env) do
      op =
        if op.status == "queued",
          do:
            Operations.mark(op, "dispatched",
              dispatched_at: DateTime.utc_now(),
              args: Map.merge(op.args || %{}, extra)
            ),
          else: op

      case Agents.dispatch(env.box_id, cmd) do
        :ok ->
          :ok

        {:error, :offline} ->
          if op.status == "dispatched" and is_nil(op.started_at),
            do: Operations.mark(op, "queued", dispatched_at: nil)

          {:error, :offline}
      end
    end
  end
end
