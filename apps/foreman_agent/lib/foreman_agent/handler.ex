defmodule ForemanAgent.Handler do
  @moduledoc "Maps each command type to the code that runs it."

  alias ForemanAgent.{Config, Docker, Env, Inventory, Redactor, Runner, Stats, Updater}
  alias ForemanProtocol.Command

  @spec handle(Command.t(), (String.t(), String.t() -> any())) ::
          {:ok, map()} | {:error, String.t()}
  def handle(%Command{type: "env." <> _ = type, payload: payload} = cmd, log) do
    redactor = Redactor.new(cmd)

    case Env.run(type, payload, ctx(Redactor.wrap_log(redactor, log))) do
      {:error, message} -> {:error, Redactor.redact(redactor, message)}
      ok -> ok
    end
  end

  def handle(%Command{type: "box.inventory"}, _log) do
    with {:ok, envs} <- inventory() do
      {:ok, %{"environments" => Enum.map(envs, &stringify/1)}}
    end
  end

  def handle(%Command{type: "box.stats"}, _log) do
    with {:ok, stats} <- Stats.collect(ctx(fn _, _ -> :ok end)) do
      {:ok, stringify(stats)}
    end
  end

  def handle(%Command{type: "box.gc"}, log), do: gc(ctx(log))

  def handle(%Command{type: "agent.update", payload: payload}, log) do
    Updater.run(payload, Config.get(), log)
  end

  def inventory do
    case Docker.list_containers(["foreman.env_id"]) do
      {:ok, containers} -> {:ok, Inventory.from_containers(containers)}
      {:error, reason} -> {:error, "couldn't list containers: #{inspect(reason)}"}
    end
  end

  def ctx(log) do
    %{config: Config.get(), runner: Runner.impl(), docker: Docker.impl(), log: log}
  end

  defp gc(ctx) do
    commands = [
      ["image", "prune", "--force"],
      ["builder", "prune", "--force", "--filter", "until=168h"],
      ["volume", "prune", "--force"]
    ]

    env = %{"DOCKER_HOST" => "unix://" <> ctx.config.docker_socket}

    Enum.reduce_while(commands, {:ok, %{}}, fn args, acc ->
      ctx.log.("info", "docker #{Enum.join(args, " ")}\n")

      case ctx.runner.run(ctx.config.docker, args, env: env, on_output: &ctx.log.("stdout", &1)) do
        {:ok, %{status: 0}} ->
          {:cont, acc}

        {:ok, %{output: output}} ->
          {:halt, {:error, "docker #{hd(args)} prune failed: #{output}"}}

        {:error, reason} ->
          {:halt, {:error, inspect(reason)}}
      end
    end)
  end

  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
