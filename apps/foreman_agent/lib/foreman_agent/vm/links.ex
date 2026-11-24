defmodule ForemanAgent.VM.Links do
  @moduledoc """
  One `ForemanAgent.VM.Link` per running environment VM, started when
  something first needs it. A link stops by itself once its VM isn't
  running, and the next use starts another.
  """

  alias ForemanAgent.VM
  alias ForemanAgent.VM.{Link, Machine, Relay}

  @registry ForemanAgent.VM.Registry
  @supervisor ForemanAgent.VM.LinkSupervisor

  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  @doc "The link to an environment's VM, started if it isn't."
  @spec get(String.t(), ForemanAgent.Config.t()) :: pid()
  def get(env_id, config) do
    case Registry.lookup(@registry, env_id) do
      [{pid, _}] ->
        pid

      [] ->
        machine = Machine.impl(config)

        spec = %{
          id: {Link, env_id},
          restart: :temporary,
          start:
            {Link, :start_link,
             [
               [
                 name: {:via, Registry, {@registry, env_id}},
                 socket: fn -> VM.pin_socket(config, env_id, :vsock) end,
                 config: hello_config(config),
                 alive?: fn -> machine.running?(env_id, config) end,
                 # The link is this environment's, so what its guest asks
                 # of the public API is asked as this environment.
                 relay: fn request -> Relay.forward(env_id, request) end
               ]
             ]}
        }

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @doc "Stops an environment's link, if it has one."
  def stop(env_id) do
    case Registry.lookup(@registry, env_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  @doc "Waits for a VM's guest agent to answer, up to `timeout` milliseconds."
  @spec await(String.t(), ForemanAgent.Config.t(), non_neg_integer()) :: :ok | :timeout
  def await(env_id, config, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(env_id, config, deadline)
  end

  defp do_await(env_id, config, deadline) do
    connected? =
      try do
        Link.connected?(get(env_id, config))
      catch
        :exit, _ -> false
      end

    cond do
      connected? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(100)
        do_await(env_id, config, deadline)
    end
  end

  # What the guest agent takes from the box (ForemanAgent.Guest.configure/1).
  defp hello_config(config) do
    %{
      "allowed_git_hosts" => config.allowed_git_hosts,
      "insecure_git_hosts" => config.insecure_git_hosts
    }
  end
end
