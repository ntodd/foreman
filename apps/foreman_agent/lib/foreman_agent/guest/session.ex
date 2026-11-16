defmodule ForemanAgent.Guest.Session do
  @moduledoc """
  One host connection to the guest agent (see `ForemanAgent.Channel`).

  Commands go to `ForemanAgent.Ops` as they would from the control plane,
  so a command the host sends again after a reconnect (same op id) gets
  the result the guest already has, or waits for the one still running.
  Their events come back through `ForemanAgent.Outbox`, which this session
  attaches to once the host says hello: results the host hasn't
  acknowledged are delivered again on every connection.

  Options (all have defaults that use the application's processes):

    * `:ops`, `:outbox` - the servers commands and events go through
    * `:queries` - `%{"inventory" => fun, "ports" => fun}`, each returning
      `{:ok, term}` or `{:error, message}`
    * `:clock` - `fn host_now_ms -> any end`, called with the host's time
    * `:configure` - `fn config_map -> any end`, called with the host's config
  """
  use GenServer

  alias ForemanAgent.{Channel, Ops, Outbox}
  alias ForemanProtocol.{Command, Event}

  require Logger

  @doc "Starts a session for an accepted socket; it reads once `go/1` hands it over."
  def start(socket, opts), do: GenServer.start(__MODULE__, {socket, opts})

  def go(pid), do: send(pid, :go)

  def close(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init({socket, opts}) do
    {:ok,
     %{
       socket: socket,
       ops: Keyword.get(opts, :ops, Ops),
       outbox: Keyword.get(opts, :outbox, Outbox),
       queries: Keyword.get_lazy(opts, :queries, &ForemanAgent.Guest.queries/0),
       clock: Keyword.get(opts, :clock, &ForemanAgent.Guest.sync_clock/1),
       configure: Keyword.get(opts, :configure, &ForemanAgent.Guest.configure/1)
     }}
  end

  @impl true
  def handle_info(:go, state) do
    :ok = :inet.setopts(state.socket, Channel.frame_opts() ++ [active: :once])
    {:noreply, state}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case Channel.decode(data) do
      {:ok, frame} -> handle_frame(frame, state)
      {:error, :malformed} -> Logger.warning("ignoring a malformed frame from the host")
    end

    :ok = :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.warning("the host connection failed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:outbox_deliver, %Event{} = event, seq}, state) do
    send_frame(state, %{"t" => "event", "seq" => seq, "event" => Event.to_wire(event)})
    {:noreply, state}
  end

  def handle_info({:reply, id, result}, state) do
    frame =
      case result do
        {:ok, value} -> %{"t" => "reply", "id" => id, "ok" => true, "result" => value}
        {:error, message} -> %{"t" => "reply", "id" => id, "ok" => false, "error" => message}
      end

    send_frame(state, frame)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
  end

  defp handle_frame(%{"t" => "hello"} = frame, state) do
    sync_clock(frame, state)
    if is_map(frame["config"]), do: state.configure.(frame["config"])
    send_frame(state, %{"t" => "hello", "agent_version" => ForemanAgent.Identity.version()})
    Outbox.attach(state.outbox, self())
  end

  defp handle_frame(%{"t" => "cmd", "cmd" => wire} = frame, state) do
    sync_clock(frame, state)

    case Command.from_wire(wire) do
      {:ok, cmd} -> Ops.submit(state.ops, cmd)
      {:error, errors} -> reject(wire, errors, state)
    end
  end

  defp handle_frame(%{"t" => "cancel", "op_id" => op_id}, state) when is_binary(op_id) do
    case Command.new("op.cancel", %{target_op_id: op_id}) do
      {:ok, cmd} -> Ops.submit(state.ops, cmd)
      {:error, _} -> :ok
    end
  end

  defp handle_frame(%{"t" => "ack", "seq" => seq}, state) when is_integer(seq),
    do: Outbox.ack(state.outbox, seq)

  defp handle_frame(%{"t" => "query", "id" => id, "q" => q}, state) when is_integer(id) do
    session = self()

    case Map.fetch(state.queries, q) do
      {:ok, fun} ->
        Task.start(fn -> send(session, {:reply, id, run_query(fun)}) end)

      :error ->
        send(session, {:reply, id, {:error, "unknown query"}})
    end
  end

  defp handle_frame(%{"t" => type}, _state),
    do: Logger.warning("ignoring a #{inspect(type)} frame from the host")

  defp run_query(fun) do
    fun.()
  rescue
    e -> {:error, "query failed: #{Exception.message(e)}"}
  end

  defp sync_clock(%{"now" => now}, state) when is_integer(now), do: state.clock.(now)
  defp sync_clock(_frame, _state), do: :ok

  # A command that fails validation still gets a result, if it has an op
  # id the host can match it to.
  defp reject(%{"op_id" => op_id}, errors, state) when is_binary(op_id) do
    case Event.new("op.result", %{
           op_id: op_id,
           status: "error",
           error: "invalid command: #{inspect(errors)}"
         }) do
      {:ok, event} -> Outbox.push(state.outbox, event)
      {:error, _} -> :ok
    end
  end

  defp reject(_wire, _errors, _state), do: :ok

  defp send_frame(state, frame) do
    case Channel.send_frame(state.socket, frame) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("couldn't send to the host: #{inspect(reason)}")
    end
  end
end
