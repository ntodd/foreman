defmodule ForemanAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    config = ForemanAgent.Config.load()
    ForemanAgent.Config.put(config)

    # Ops holds the running operations and Outbox their unsent results, so
    # they sit apart from the link to the control plane: a socket or
    # reporting fault that keeps restarting exhausts the link's supervisor
    # (which then restarts, as one restart up here) rather than this one,
    # which would stop the agent and every operation with it.
    link = %{
      id: ForemanAgent.LinkSupervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [ForemanAgent.Reporter, ForemanAgent.Connection],
           [
             strategy: :one_for_one,
             max_restarts: 10,
             max_seconds: 60,
             name: ForemanAgent.LinkSupervisor
           ]
         ]}
    }

    children =
      [ForemanAgent.Outbox, ForemanAgent.Ops] ++ if(config.connect, do: [link], else: [])

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 60,
      name: ForemanAgent.Supervisor
    )
  end
end
