defmodule ForemanAgent.Application do
  @moduledoc false
  use Application

  alias ForemanAgent.VM.Links

  @impl true
  def start(_type, _args) do
    config = ForemanAgent.Config.load()
    ForemanAgent.Config.put(config)
    ForemanAgent.Env.sweep_docker_configs(config)

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
      case config.mode do
        # In an environment's VM: commands come from the box's agent.
        :guest ->
          [
            ForemanAgent.Outbox,
            {ForemanAgent.Ops, handler: &ForemanAgent.Guest.handle/2},
            {ForemanAgent.Guest.Server, path: config.guest_socket}
          ]

        :host ->
          Links.child_specs() ++
            [ForemanAgent.Outbox, ForemanAgent.Ops] ++ if(config.connect, do: [link], else: [])
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 60,
      name: ForemanAgent.Supervisor
    )
  end
end
