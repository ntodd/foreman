defmodule Foreman.Ports do
  @moduledoc """
  The TCP ports listening in each running environment, as its box last
  reported them (`box.ports`), for links on the environment's page.

  Kept in memory: a box reports them again after every join and every
  minute, so a restarted control plane soon has them back.
  An environment's page hears about a change on the environment's topic
  as `{:ports, env_id, ports}`; `ports` is nil when it's no longer known.
  """
  use GenServer

  alias Foreman.Environments

  @table __MODULE__
  @max_ports 100

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Records a box's report: `%{env_id => [%{port: 4000, process: "beam.smp"}]}`.
  Only the box's own live environments count. One left out is unknown
  again (stopped, or the box couldn't read it), and so is anything the
  box had before that's gone (destroyed).
  """
  def record(box_id, environments) do
    live = Environments.live_slugs_for_box(box_id)

    known =
      :ets.match(@table, {:"$1", box_id, :_}) |> List.flatten() |> MapSet.new()

    reported =
      for {env_id, ports} <- environments,
          Map.has_key?(live, env_id),
          into: %{},
          do: {env_id, Enum.take(ports, @max_ports)}

    for env_id <- MapSet.union(known, MapSet.new(Map.keys(reported))) do
      ports = Map.get(reported, env_id)

      if ports != for_environment(env_id) do
        if ports,
          do: :ets.insert(@table, {env_id, box_id, ports}),
          else: :ets.delete(@table, env_id)

        Phoenix.PubSub.broadcast(
          Foreman.PubSub,
          "environment:" <> env_id,
          {:ports, env_id, ports}
        )
      end
    end

    :ok
  end

  @doc """
  An environment's listening ports, sorted: [] when nothing is listening,
  nil when its box hasn't said.
  """
  def for_environment(env_id) do
    case :ets.lookup(@table, env_id) do
      [{_, _box_id, ports}] -> ports
      [] -> nil
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
