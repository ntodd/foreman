defmodule ForemanAgent.Reporter do
  @moduledoc """
  Reports the box's inventory (every 15 seconds, when it changes), host
  metrics (every 5 seconds) and stats (every 30 seconds) to the control
  plane, and an `env.state` event for each environment whose state
  changed in between.
  """
  use GenServer

  alias ForemanAgent.{Handler, HostMetrics, Outbox, Stats}
  alias ForemanProtocol.Event

  require Logger

  @inventory_every 15_000
  @stats_every 30_000
  @metrics_every 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def report_now, do: GenServer.cast(__MODULE__, :report_now)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :inventory, @inventory_every)
    Process.send_after(self(), :stats, @stats_every)
    send(self(), :metrics)
    {:ok, %{states: %{}, last: nil, cpu: nil}}
  end

  @impl true
  def handle_cast(:report_now, state) do
    state = %{state | last: nil}
    {:noreply, state |> inventory() |> tap(fn _ -> stats() end)}
  end

  @impl true
  def handle_info(:inventory, state) do
    Process.send_after(self(), :inventory, @inventory_every)
    {:noreply, inventory(state)}
  end

  def handle_info(:stats, state) do
    Process.send_after(self(), :stats, @stats_every)
    stats()
    {:noreply, state}
  end

  def handle_info(:metrics, state) do
    Process.send_after(self(), :metrics, @metrics_every)
    ctx = Handler.ctx(fn _, _ -> :ok end)

    source = %{
      proc: "/proc",
      disk: fn -> Stats.disk(ctx) end,
      now: System.system_time(:second)
    }

    {metrics, cpu} = HostMetrics.sample(source, state.cpu)
    # The first sample has no CPU baseline yet.
    if state.cpu, do: push("box.metrics", metrics)
    {:noreply, %{state | cpu: cpu}}
  end

  defp inventory(state) do
    case Handler.inventory() do
      {:ok, envs} ->
        if envs != state.last, do: push("box.inventory", %{environments: envs})

        states = Map.new(envs, &{&1.env_id, &1.state})

        for {env_id, s} <- states, Map.get(state.states, env_id) not in [nil, s] do
          push("env.state", %{env_id: env_id, state: s})
        end

        for {env_id, _} <- state.states, not Map.has_key?(states, env_id) do
          push("env.state", %{env_id: env_id, state: "missing"})
        end

        %{state | states: states, last: envs}

      {:error, message} ->
        Logger.warning(message)
        state
    end
  end

  defp stats do
    case Stats.collect(Handler.ctx(fn _, _ -> :ok end)) do
      {:ok, stats} -> push("box.stats", stats)
      {:error, message} -> Logger.warning(message)
    end
  end

  defp push(type, payload) do
    case Event.new(type, payload) do
      {:ok, event} -> Outbox.push(event)
      {:error, errors} -> Logger.warning("invalid #{type}: #{inspect(errors)}")
    end
  end
end
