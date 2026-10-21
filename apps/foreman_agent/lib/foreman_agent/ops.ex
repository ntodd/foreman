defmodule ForemanAgent.Ops do
  @moduledoc """
  Runs commands from the control plane.

  - **Idempotent:** a command is identified by its `op_id`. A retry of one
    that's queued or running is ignored; a retry of one that finished gets
    its stored result again. The control plane resends commands after a
    reconnect, so this is what stops them running twice.
  - **Ordered per environment:** operations on the same environment run one
    at a time, in arrival order. Box commands run straight away.
  - **Cancellable:** `op.cancel` kills a running operation's process and
    every process its commands started (`ForemanAgent.Runner.Tree`), or
    drops a queued one. One it doesn't know is recorded as cancelled, so it
    won't run if it turns up later. The environment's next operation waits
    until the cancelled one's processes are gone.

  Each operation runs in its own process and reports `op.accepted`,
  `op.log` and `op.result` events to the sink.
  """
  use GenServer

  alias ForemanAgent.Runner.Tree
  alias ForemanAgent.Text
  alias ForemanProtocol.{Command, Event}

  require Logger

  @max_done 500
  # How long a cancelled operation's commands get to exit after SIGTERM.
  @cancel_grace 10_000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec submit(GenServer.server(), Command.t()) :: :accepted | :duplicate
  def submit(server \\ __MODULE__, %Command{} = cmd), do: GenServer.call(server, {:submit, cmd})

  @spec in_flight(GenServer.server()) :: [String.t()]
  def in_flight(server \\ __MODULE__), do: GenServer.call(server, :in_flight)

  @impl true
  def init(opts) do
    {:ok,
     %{
       handler: Keyword.get(opts, :handler, &ForemanAgent.Handler.handle/2),
       sink: Keyword.get(opts, :sink, &ForemanAgent.Outbox.push/1),
       running: %{},
       pids: %{},
       queues: %{},
       # Cancelled operations whose processes are still being stopped:
       # reaper pid => queue key. Their queue waits.
       draining: %{},
       known: MapSet.new(),
       done: %{},
       done_order: :queue.new()
     }}
  end

  @impl true
  def handle_call({:submit, %Command{type: "op.cancel"} = cmd}, _from, state) do
    state = cancel(state, cmd.payload.target_op_id)
    emit(state, "op.result", %{op_id: cmd.op_id, status: "ok"})
    {:reply, :accepted, state}
  end

  def handle_call({:submit, %Command{op_id: op_id} = cmd}, _from, state) do
    cond do
      Map.has_key?(state.done, op_id) ->
        state.sink.(state.done[op_id])
        {:reply, :duplicate, state}

      MapSet.member?(state.known, op_id) ->
        emit(state, "op.accepted", %{op_id: op_id})
        {:reply, :duplicate, state}

      true ->
        emit(state, "op.accepted", %{op_id: op_id})
        key = key(cmd)
        state = %{state | known: MapSet.put(state.known, op_id)}
        state = update_in(state.queues[key], &:queue.in(cmd, &1 || :queue.new()))
        {:reply, :accepted, maybe_start(state, key)}
    end
  end

  def handle_call(:in_flight, _from, state), do: {:reply, MapSet.to_list(state.known), state}

  @impl true
  def handle_info({:op_done, op_id, result}, state) do
    case Map.fetch(state.running, op_id) do
      {:ok, %{pid: pid, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish(state, op_id, pid, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case {Map.fetch(state.pids, pid), Map.pop(state.draining, pid)} do
      {{:ok, op_id}, _} ->
        Logger.error("operation #{op_id} crashed: #{Exception.format_exit(reason)}")
        {:noreply, finish(state, op_id, pid, {:error, crash_message(reason)})}

      {:error, {nil, _}} ->
        {:noreply, state}

      {:error, {key, draining}} ->
        {:noreply, maybe_start(%{state | draining: draining}, key)}
    end
  end

  # The reason can carry the command's payload (secrets included), so the
  # control plane only hears what kind of crash it was. The agent's own
  # log has the details.
  defp crash_message({%{__exception__: true} = e, _stack}),
    do: "operation crashed (#{inspect(e.__struct__)})"

  defp crash_message(_reason), do: "operation crashed"

  # Environment commands queue behind each other; everything else gets a
  # queue of its own.
  defp key(%Command{payload: %{env_id: env_id}}), do: {:env, env_id}
  defp key(%Command{op_id: op_id}), do: {:op, op_id}

  defp maybe_start(state, key) do
    busy? =
      Enum.any?(state.running, fn {_, r} -> r.key == key end) or
        key in Map.values(state.draining)

    case {busy?, :queue.out(state.queues[key] || :queue.new())} do
      {true, _} ->
        state

      {false, {:empty, _}} ->
        %{state | queues: Map.delete(state.queues, key)}

      {false, {{:value, cmd}, rest}} ->
        state = %{state | queues: Map.put(state.queues, key, rest)}
        start(state, cmd, key)
    end
  end

  defp start(state, cmd, key) do
    parent = self()
    handler = state.handler
    sink = state.sink
    op_id = cmd.op_id

    log = fn stream, data ->
      case Event.new("op.log", %{op_id: op_id, stream: stream, data: Text.scrub(data)}) do
        {:ok, event} -> sink.(event)
        {:error, _} -> :ok
      end
    end

    {pid, ref} =
      spawn_monitor(fn ->
        Logger.metadata(op_id: op_id)
        send(parent, {:op_done, op_id, handler.(cmd, log)})
      end)

    %{
      state
      | running: Map.put(state.running, op_id, %{pid: pid, ref: ref, key: key}),
        pids: Map.put(state.pids, pid, op_id)
    }
  end

  defp finish(state, op_id, pid, result) do
    %{key: key} = state.running[op_id]
    event = result_event(op_id, result)
    state.sink.(event)

    state
    |> Map.update!(:running, &Map.delete(&1, op_id))
    |> Map.update!(:pids, &Map.delete(&1, pid))
    |> Map.update!(:known, &MapSet.delete(&1, op_id))
    |> remember(op_id, event)
    |> maybe_start(key)
  end

  defp cancel(state, target) do
    case Map.fetch(state.running, target) do
      {:ok, %{pid: pid, ref: ref, key: key}} ->
        Process.demonitor(ref, [:flush])
        draining = Map.put(state.draining, reap(pid), key)
        finish(%{state | draining: draining}, target, pid, {:error, "cancelled"})

      :error ->
        cancel_queued(state, target)
    end
  end

  # Freezes the operation where it is (so it can't start another command or
  # report a result), stops every process its commands started, then kills
  # it. This runs apart from Ops, so a slow shutdown doesn't hold up other
  # commands.
  defp reap(pid) do
    suspended? =
      try do
        :erlang.suspend_process(pid)
      catch
        :error, :badarg -> false
      end

    roots = if suspended?, do: Tree.os_pids(pid), else: []

    {reaper, _ref} =
      spawn_monitor(fn ->
        Tree.terminate(roots, @cancel_grace)
        Process.exit(pid, :kill)
      end)

    reaper
  end

  defp cancel_queued(state, target) do
    case Enum.find(state.queues, fn {_k, q} ->
           Enum.any?(:queue.to_list(q), &(&1.op_id == target))
         end) do
      {key, queue} ->
        queue = :queue.filter(&(&1.op_id != target), queue)
        event = result_event(target, {:error, "cancelled"})
        state.sink.(event)

        %{
          state
          | queues: Map.put(state.queues, key, queue),
            known: MapSet.delete(state.known, target)
        }
        |> remember(target, event)

      nil ->
        tombstone(state, target)
    end
  end

  # After a restart, a cancel can arrive before the control plane's resend
  # of the operation it's for. Recorded as cancelled, the resend gets that
  # result instead of running. One that already finished keeps its result.
  defp tombstone(state, target) do
    if Map.has_key?(state.done, target) do
      state
    else
      event = result_event(target, {:error, "cancelled"})
      state.sink.(event)
      remember(state, target, event)
    end
  end

  defp result_event(op_id, result) do
    payload =
      case Text.scrub(result) do
        {:ok, map} when is_map(map) ->
          %{op_id: op_id, status: "ok", result: map}

        :ok ->
          %{op_id: op_id, status: "ok"}

        {:error, message} when is_binary(message) ->
          %{op_id: op_id, status: "error", error: message}

        {:error, message, map} when is_binary(message) and is_map(map) ->
          %{op_id: op_id, status: "error", error: message, result: map}

        other ->
          %{op_id: op_id, status: "error", error: "unexpected result: #{inspect(other)}"}
      end

    case Event.new("op.result", payload) do
      {:ok, event} ->
        event

      {:error, errors} ->
        Logger.error("invalid op.result for #{op_id}: #{inspect(errors)}")

        {:ok, event} =
          Event.new("op.result", %{op_id: op_id, status: "error", error: "invalid result"})

        event
    end
  end

  defp remember(state, op_id, event) do
    order = :queue.in(op_id, state.done_order)
    done = Map.put(state.done, op_id, event)

    if :queue.len(order) > @max_done do
      {{:value, oldest}, order} = :queue.out(order)
      %{state | done: Map.delete(done, oldest), done_order: order}
    else
      %{state | done: done, done_order: order}
    end
  end

  defp emit(state, type, payload) do
    {:ok, event} = Event.new(type, payload)
    state.sink.(event)
  end
end
