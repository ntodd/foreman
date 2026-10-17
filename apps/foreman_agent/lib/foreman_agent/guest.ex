defmodule ForemanAgent.Guest do
  @moduledoc """
  The agent inside an environment's VM. The host runs it once per
  operation (see `ForemanAgent.Env.Vm`):

      bin/foreman_agent eval 'ForemanAgent.Guest.main("/var/lib/foreman-agent/ops/<id>.op")'

  It reads the request the host pushed, deletes it (it carries secrets),
  runs the operation with `ForemanAgent.Env` against the VM's own Docker
  and paths, and prints logs and the result for the host
  (`ForemanAgent.Guest.Wire`). Nothing else of the agent starts: no
  connection, no reporting.
  """

  alias ForemanAgent.{Config, Docker, Env, Runner}
  alias ForemanAgent.Guest.Wire

  # What Env needs at runtime: MuonTrap for commands, Req for the Docker
  # Engine API, and their dependencies.
  @apps [:crypto, :public_key, :ssl, :inets, :muontrap, :req]

  @doc "Entry point for `bin/foreman_agent eval`."
  def main(path) do
    {:ok, _} = Application.ensure_all_started(@apps)
    config = Config.load()
    Config.put(config)

    emit = &IO.binwrite(:stdio, &1)
    ctx = %{config: config, runner: Runner.Local, docker: Docker.Engine}

    request =
      case File.read(path) do
        {:ok, binary} ->
          File.rm(path)
          binary

        {:error, _} ->
          ""
      end

    run_request(request, ctx, emit)
  end

  @doc false
  def run_request(request, ctx, emit) do
    result =
      case Wire.decode_request(request) do
        {:ok, {type, payload}} -> run(type, payload, Map.put(ctx, :log, log_fun(emit)))
        {:error, _} -> {:error, "the host's request couldn't be read"}
      end

    emit.(Wire.result(result))
    :ok
  end

  @doc false
  def log_fun(emit), do: fn stream, data -> emit.(Wire.log(stream, data)) end

  # The host redacts what comes back; the message of a crash can hold
  # anything the payload carried, so only its type crosses.
  defp run(type, payload, ctx) do
    Env.run(type, payload, ctx)
  rescue
    e -> {:error, "operation crashed: #{inspect(e.__struct__)}"}
  catch
    kind, _ -> {:error, "operation crashed (#{kind})"}
  end
end
