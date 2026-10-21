defmodule ForemanWeb.AgentChannel do
  @moduledoc """
  One connected agent. Commands go out as `command` pushes; events come
  back as `event` messages and are answered with a reply, which is how
  the agent knows a result was recorded.
  """
  use Phoenix.Channel

  alias Foreman.{Agents, Boxes}
  alias ForemanProtocol.{Command, Event}

  require Logger

  @impl true
  def join("agent:" <> box_id, payload, %{assigns: %{box_id: box_id}} = socket) do
    with {:ok, join} <- ForemanProtocol.cast_join(payload),
         true <- ForemanProtocol.compatible?(join.protocol_version) || {:error, :protocol},
         %Boxes.Box{revoked_at: nil} = box <- Boxes.get_box(box_id) do
      # Before registering: once registered the box is online, and
      # Housekeeping would judge the operations about to be resent by when
      # they were first sent.
      :ok = Agents.restart_clocks(box_id, join.in_flight)
      :ok = Agents.register(box_id)
      box = Boxes.agent_joined(box, join)
      Logger.metadata(box_id: box_id)

      Logger.info(
        "agent #{box.name} joined (#{join.agent_version}, protocol #{join.protocol_version})"
      )

      send(self(), :after_join)
      {:ok, assign(socket, :box, box)}
    else
      {:error, :protocol} -> {:error, %{reason: "unsupported protocol version"}}
      {:error, _errors} -> {:error, %{reason: "invalid join payload"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info(:after_join, socket) do
    Agents.agent_connected(socket.assigns.box)
    {:noreply, socket}
  end

  def handle_info({:dispatch, %Command{} = cmd}, socket) do
    push(socket, "command", Command.to_wire(cmd))
    {:noreply, socket}
  end

  @impl true
  def handle_in("event", wire, socket) do
    case Event.from_wire(wire) do
      {:ok, event} ->
        case Agents.handle_event(socket.assigns.box_id, event) do
          :ok -> {:reply, {:ok, %{}}, socket}
          {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end

      {:error, errors} ->
        Logger.warning("invalid event from agent: #{inspect(errors)}")
        {:reply, {:error, %{reason: "invalid event"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unknown message"}}, socket}

  # Phoenix calls this for a refused join too, which never had a box.
  @impl true
  def terminate(_reason, %{assigns: %{box: _}} = socket) do
    Boxes.agent_left(socket.assigns.box_id)
    :ok
  end

  def terminate(_reason, _socket), do: :ok
end
