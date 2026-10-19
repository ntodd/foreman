defmodule ForemanAgent.Reporter do
  @moduledoc """
  Reports the box's inventory (every 15 seconds, when it changes), host
  metrics (every 5 seconds) and stats (every 30 seconds) to the control
  plane, an `env.state` event for each environment whose state changed in
  between, and the box's firewall when it changes from what the join
  said.
  """
  use GenServer

  alias ForemanAgent.{Config, Firewall, Handler, HostMetrics, Outbox, Stats}
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
    {:ok, %{states: %{}, last: nil, cpu: nil, firewall: nil}}
  end

  # Each report is best effort: a failure (Docker restarting, no file
  # descriptors left for `df`) is logged and skipped. Crashing instead
  # would restart this process straight into the same failure, and enough
  # restarts in a row take the whole agent down with it.
  @impl true
  def handle_cast(:report_now, state) do
    state = safely("inventory", state, &inventory(%{&1 | last: nil}))
    # Sent again after every join: the firewall may have changed and
    # changed back since this process last looked.
    state = safely("firewall", state, &firewall(%{&1 | firewall: nil}))
    safely("stats", state, &tap(&1, fn _ -> stats() end))
    {:noreply, state}
  end

  @impl true
  def handle_info(:inventory, state) do
    Process.send_after(self(), :inventory, @inventory_every)
    state = safely("inventory", state, &inventory/1)
    {:noreply, safely("firewall", state, &firewall/1)}
  end

  def handle_info(:stats, state) do
    Process.send_after(self(), :stats, @stats_every)
    {:noreply, safely("stats", state, &tap(&1, fn _ -> stats() end))}
  end

  def handle_info(:metrics, state) do
    Process.send_after(self(), :metrics, @metrics_every)
    {:noreply, safely("metrics", state, &metrics/1)}
  end

  defp safely(what, state, fun) do
    fun.(state)
  rescue
    e ->
      Logger.warning("couldn't report #{what}: #{Exception.message(e)}")
      state
  catch
    kind, reason ->
      Logger.warning("couldn't report #{what}: #{Exception.format_banner(kind, reason)}")
      state
  end

  defp metrics(state) do
    ctx = Handler.ctx(fn _, _ -> :ok end)

    source = %{
      proc: "/proc",
      disk: fn -> Stats.disk(ctx) end,
      now: System.system_time(:second)
    }

    {metrics, cpu} = HostMetrics.sample(source, state.cpu)
    # The first sample has no CPU baseline yet.
    if state.cpu, do: push("box.metrics", metrics)
    %{state | cpu: cpu}
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

  defp firewall(state) do
    case Firewall.report(Config.get()) do
      same when same == state.firewall ->
        state

      report ->
        push("box.firewall", report)
        %{state | firewall: report}
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
