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
  alias Foreman.Environments.{Commands, Environment, WorkloadAccess}
  alias Foreman.Operations.Operation

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
      %{status: status, environment_id: ^env_id} = op when status in ["dispatched", "running"] ->
        if Operations.cancel_requested?(op) do
          Agents.cancel_operation(op, nil)
        else
          env = Repo.get!(Environment, env_id)
          resend_op(op, env)
        end

      _ ->
        :ok
    end
  end

  defp rewrite_secrets(env, original) do
    op = %Operation{
      id: Ecto.UUID.generate(),
      environment_id: env.id,
      box_id: env.box_id,
      user_id: original.user_id,
      api_grant_id: original.api_grant_id,
      action: "secrets_write",
      command: "env.secrets.write",
      args: %{}
    }

    # The source operation owns retries. A temporary verification outage must not
    # leave detached file writes behind for each reconnect.
    with {:ok, cmd, extra, policy} <- Commands.prepare(op, env) do
      dispatch_built(Repo.insert!(op), env, cmd, extra, policy)
    end
  end

  @impl true
  def handle_info(:timeout, env_id), do: {:noreply, env_id, :hibernate}

  def handle_info({:retry, op_id}, env_id) do
    case Operations.get(op_id) do
      %{status: "queued"} -> dispatch_next(env_id)
      %{status: status} when status in ["dispatched", "running"] -> do_resend(env_id, op_id)
      _ -> :ok
    end

    {:noreply, env_id, @idle_timeout}
  end

  defp retry(op) do
    unless sync?(), do: Process.send_after(self(), {:retry, op.id}, 30_000)
    :retry
  end

  defp dispatch_next(env_id) do
    env = Repo.get(Environment, env_id)

    cond do
      is_nil(env) ->
        :ok

      Operations.in_flight(env_id) ->
        :ok

      not Boxes.online?(env.box_id) ->
        :ok

      Foreman.Jobs.EnvironmentExpiry.due?(env) ->
        if op = Foreman.Jobs.EnvironmentExpiry.next_due(env_id), do: dispatch(op, env)

      op = Operations.next_queued(env_id, env.created_once) ->
        if Environments.supersede_queued_shutdown(op),
          do: dispatch_next(env_id),
          else: dispatch(op, env)

      true ->
        :ok
    end
  end

  defp dispatch(op, %Environment{destroyed_at: destroyed} = env) when not is_nil(destroyed) do
    Operations.cancel_queued(op)
    dispatch_next(env.id)
  end

  defp dispatch(%{action: "secrets_write"} = op, %{desired_state: state} = env)
       when state in ["stopped", "destroyed"] do
    Operations.cancel_queued(op)
    dispatch_next(env.id)
  end

  # Builds the command fresh (current secrets and token), takes the
  # operation off the queue and records the transitional state, then
  # sends. The state goes first so a fast result can't be overwritten by
  # it; the state it replaced is kept so a failed stop can go back to it.
  defp dispatch(op, env) do
    case Commands.prepare(op, env) do
      {:ok, cmd, extra, policy} ->
        dispatch_built(op, env, cmd, extra, policy)

      :retry ->
        retry(op)

      :superseded ->
        Operations.cancel_queued(op)
        dispatch_next(env.id)

      {:error, :unauthorized} ->
        with {:ok, failed} <-
               Operations.deny_workload(op, :queued),
             do: Environments.dispatch_denied(failed, env)

        :denied

      {:error, message} ->
        Logger.warning("couldn't send #{op.action} for #{env.slug}: #{message}")

        with {:ok, op} <- Operations.fail_queued(op, message), do: Environments.apply_result(op)
    end
  end

  defp dispatch_built(op, env, cmd, extra, policy) do
    state = Environments.transitional_state(op.action)
    extra = if state, do: Map.put(extra, "prior_state", env.observed_state), else: extra

    case Operations.claim(op,
           dispatched_at: DateTime.utc_now(),
           args: Map.merge(op.args || %{}, extra)
         ) do
      {:ok, op} -> send_claimed(op, cmd, env, state, policy)
      # Cancelled since it was read.
      :error -> dispatch_next(env.id)
    end
  end

  defp send_claimed(op, cmd, env, state, policy) do
    updated =
      if state,
        do: Environments.update_env!(env, %{observed_state: state, status_message: nil}),
        else: env

    Foreman.Operations.Redactions.put(op.id, cmd, env)

    case deliver(op, env, cmd, policy) do
      :ok ->
        :ok

      :superseded ->
        Operations.cancel_unsent(op)
        dispatch_next(env.id)
        :ok

      {:error, :unauthorized} ->
        if state, do: Environments.update_env!(updated, %{observed_state: env.observed_state})
        deny_sent(op, env, :claimed)
        {:error, :unauthorized}

      :retry ->
        Operations.mark(op, "queued", dispatched_at: nil)
        if state, do: Environments.update_env!(updated, %{observed_state: env.observed_state})
        retry(op)

      # Gone since the check: back to the queue, and to the state it was in.
      {:error, :offline} ->
        Operations.mark(op, "queued", dispatched_at: nil)
        if state, do: Environments.update_env!(updated, %{observed_state: env.observed_state})
        :ok
    end
  end

  defp deliver(op, env, cmd, policy, phase \\ :dispatch) do
    WorkloadAccess.deliver(op, env, policy, phase, fn current ->
      with :ok <- Agents.dispatch(current.box_id, cmd) do
        remember_enrollment(cmd.payload, current)
        bind_workload_grant(op, current)
        :ok
      end
    end)
  end

  defp remember_enrollment(%{files: %{"ts-authkey" => key}, tailscale: %{tags: tags}}, env)
       when env.ts_authkey != key or env.ts_authkey_tags != tags do
    Environments.update_env!(env, %{ts_authkey: key, ts_authkey_tags: tags})
  end

  defp remember_enrollment(_payload, _env), do: :ok

  defp deny_sent(op, env, phase) do
    with {:ok, failed} <- Operations.deny_workload(op, phase),
         do: Environments.dispatch_denied(failed, env)
  end

  defp bind_workload_grant(%{action: "start", api_grant_id: id}, env)
       when not is_nil(id) and env.workload_grant_id != id do
    Environments.update_env!(env, %{workload_grant_id: id})
  end

  defp bind_workload_grant(_op, _env), do: :ok

  # Rebuilds the command (current secrets and token) and sends it again.
  # If it can't be rebuilt, it fails rather than sitting there as if it
  # were on the box, holding up the queue; it's failed the way Housekeeping
  # does, so a result from a box that was running it after all still wins.
  # What the rebuilt command carries (the secrets' hashes, whether it has
  # a token) replaces what the first send recorded, since that's what the
  # result will be judged against. The state before it began stays.
  defp resend_op(op, env) do
    result =
      with {:ok, _} <- WorkloadAccess.authorize(op, env),
           :ok <- resend_files(op, env),
           do: Commands.prepare(op, env)

    case result do
      {:ok, cmd, extra, policy} ->
        Foreman.Operations.refresh_args(op, Map.delete(extra, "prior_state"))
        Foreman.Operations.Redactions.put(op.id, cmd, env)

        case deliver(op, env, cmd, policy, :reconnect) do
          :retry -> retry(op)
          {:error, :unauthorized} -> deny_sent(op, env, :reconnect)
          other -> other
        end

      :retry ->
        retry(op)

      # The agent already owns this command. Its result still settles this
      # operation even when a sibling has fulfilled the same expiry.
      :superseded ->
        :ok

      {:error, :unauthorized} ->
        deny_sent(op, env, :reconnect)

      {:error, message} ->
        Logger.warning("couldn't resend #{op.action} for #{env.slug}: #{message}")

        with {:ok, op, env} <- Operations.timed_out(op, message, &Environments.record_result/1),
             do: Environments.after_result(op, env)
    end
  end

  defp resend_files(%{action: action, command: command} = op, env)
       when action in @needs_files and command != "env.create" do
    rewrite_secrets(env, op)
  end

  defp resend_files(_op, _env), do: :ok
end
