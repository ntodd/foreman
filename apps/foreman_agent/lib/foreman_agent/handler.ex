defmodule ForemanAgent.Handler do
  @moduledoc "Maps each command type to the code that runs it."

  alias ForemanAgent.{
    Config,
    Docker,
    Env,
    Inventory,
    Ops,
    Outbox,
    Redactor,
    Runner,
    Stats,
    Updater
  }

  alias ForemanProtocol.Command

  require Logger

  # Pruning a big build cache can take a while; a hung daemon shouldn't
  # hold the command forever.
  @gc_timeout :timer.minutes(30)

  @spec handle(Command.t(), (String.t(), String.t() -> any())) ::
          {:ok, map()} | {:error, String.t()}
  def handle(%Command{type: "env." <> _ = type, payload: payload} = cmd, log) do
    redactor = Redactor.new(cmd)

    case run_env(type, payload, ctx(Redactor.wrap_log(redactor, log)), redactor) do
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

  def handle(%Command{type: "agent.update", payload: payload} = cmd, log) do
    with {:ok, result} <- Updater.run(payload, Config.get(), log) do
      if result["restart"] and Application.get_env(:foreman_agent, :exit_after_update, true) do
        restart_when_idle(cmd.op_id)
      end

      {:ok, result}
    end
  end

  # Exits once this update's result and every other operation are done, so
  # systemd (or the box's loop) starts the new release. Exiting sooner
  # would kill builds in progress and lose their results. A box that's
  # never idle (a stream of commands) restarts anyway after an hour.
  defp restart_when_idle(op_id) do
    spawn(fn ->
      Process.sleep(3_000)

      busy? = fn ->
        Enum.any?(Ops.in_flight(), &(&1 != op_id)) or not Outbox.settled?()
      end

      if await_idle(busy?, 2_000, :timer.hours(1)) == :timeout do
        Logger.warning("restarting for the update with operations still running")
      end

      System.stop(0)
    end)
  end

  @doc false
  @spec await_idle((-> boolean()), pos_integer(), non_neg_integer()) :: :idle | :timeout
  def await_idle(busy?, poll, remaining) do
    cond do
      not busy?.() ->
        :idle

      remaining <= 0 ->
        :timeout

      true ->
        Process.sleep(poll)
        await_idle(busy?, poll, remaining - poll)
    end
  end

  # A crash comes back as an error the caller redacts: the exception's
  # message can hold anything the command carried.
  defp run_env(type, payload, ctx, redactor) do
    Env.run(type, payload, ctx)
  rescue
    e ->
      Logger.error(Redactor.redact(redactor, Exception.format(:error, e, __STACKTRACE__)))
      {:error, "operation crashed: #{Exception.message(e)}"}
  catch
    kind, reason ->
      Logger.error(Redactor.redact(redactor, Exception.format(kind, reason, __STACKTRACE__)))
      {:error, "operation crashed (#{kind})"}
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

      opts = [env: env, on_output: &ctx.log.("stdout", &1), timeout: @gc_timeout]

      case ctx.runner.run(ctx.config.docker, args, opts) do
        {:ok, %{status: 0}} ->
          {:cont, acc}

        {:ok, %{status: :timeout}} ->
          {:halt, {:error, "docker #{hd(args)} prune timed out"}}

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
