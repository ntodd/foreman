defmodule Foreman.Environments.Server do
  @moduledoc """
  Sends one environment's operations to its box, one at a time.

  The queue lives in the database (operations with status `queued`), so
  nothing is lost when the control plane restarts; this process only
  serializes dispatch for its environment. It's started on demand and
  hibernates after a minute idle. (It doesn't stop: a kick cast while it
  was stopping would be lost.)

  Operations that were sent but hadn't finished when the agent
  disconnected are resent with the same op_id on reconnect; the agent
  recognises a repeat and won't run it twice. A resent start or restart
  gets a fresh secrets write ahead of it, since a reboot clears the
  box's secrets tmpfs and those commands carry no files.
  """
  use GenServer, restart: :temporary

  alias Foreman.{Agents, Boxes, Environments, Operations, Repo}
  alias Foreman.Environments.{Commands, Environment}

  require Logger

  @idle_timeout 60_000
  @needs_files ~w(start restart_affected restart_all)

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
      # Someone asked for it to stop, and the cancel may have been lost with
      # the connection. Sending the operation again would run it.
      %{status: status} = op when status in ["dispatched", "running"] ->
        if Operations.cancel_requested?(op) do
          Agents.cancel_operation(op, nil)
        else
          env = Repo.get!(Environment, env_id)
          if op.action in @needs_files, do: rewrite_secrets(env)
          resend_op(op, env)
        end

      _ ->
        :ok
    end
  end

  defp rewrite_secrets(env) do
    op =
      Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: env.id,
        box_id: env.box_id,
        action: "secrets_write",
        command: "env.secrets.write",
        args: %{}
      })

    dispatch(op, env)
  end

  @impl true
  def handle_info(:timeout, env_id), do: {:noreply, env_id, :hibernate}

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

  # Builds the command fresh (current secrets and token), takes the
  # operation off the queue and records the transitional state, then
  # sends. The state goes first so a fast result can't be overwritten by
  # it; the state it replaced is kept so a failed stop can go back to it.
  defp dispatch(op, env) do
    case Commands.build(op, env) do
      {:ok, cmd, extra} ->
        state = Environments.transitional_state(op.action)
        extra = if state, do: Map.put(extra, "prior_state", env.observed_state), else: extra

        case Operations.claim(op,
               dispatched_at: DateTime.utc_now(),
               args: Map.merge(op.args || %{}, extra)
             ) do
          {:ok, op} -> send_claimed(op, cmd, env, state)
          # Cancelled since it was read.
          :error -> dispatch_next(env.id)
        end

      {:error, message} ->
        Logger.warning("couldn't send #{op.action} for #{env.slug}: #{message}")

        with {:ok, op} <- Operations.fail_queued(op, message), do: Environments.apply_result(op)
    end
  end

  defp send_claimed(op, cmd, env, state) do
    updated =
      if state,
        do: Environments.update_env!(env, %{observed_state: state, status_message: nil}),
        else: env

    Foreman.Operations.Redactions.put(op.id, cmd, env)

    case Agents.dispatch(env.box_id, cmd) do
      :ok ->
        :ok

      # Gone since the check: back to the queue, and to the state it was in.
      {:error, :offline} ->
        Operations.mark(op, "queued", dispatched_at: nil)
        if state, do: Environments.update_env!(updated, %{observed_state: env.observed_state})
        :ok
    end
  end

  # Rebuilds the command (current secrets and token) and sends it again.
  # If it can't be rebuilt, it fails rather than sitting there as if it
  # were on the box, holding up the queue; it's failed the way Housekeeping
  # does, so a result from a box that was running it after all still wins.
  defp resend_op(op, env) do
    case Commands.build(op, env) do
      {:ok, cmd, _extra} ->
        Foreman.Operations.Redactions.put(op.id, cmd, env)
        Agents.dispatch(env.box_id, cmd)

      {:error, message} ->
        Logger.warning("couldn't resend #{op.action} for #{env.slug}: #{message}")

        with {:ok, op, env} <- Operations.timed_out(op, message, &Environments.record_result/1),
             do: Environments.after_result(op, env)
    end
  end
end
