defmodule ForemanAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    config = ForemanAgent.Config.load()
    ForemanAgent.Config.put(config)

    children =
      [ForemanAgent.Outbox, ForemanAgent.Ops] ++
        if(config.connect, do: [ForemanAgent.Reporter, ForemanAgent.Connection], else: [])

    Supervisor.start_link(children, strategy: :one_for_one, name: ForemanAgent.Supervisor)
  end
end
