defmodule ForemanAgent.Runner.Local do
  @moduledoc """
  `ForemanAgent.Runner` on MuonTrap.

  Cancelling an operation, or a command running past its `:timeout`, kills
  the command's whole process tree (`ForemanAgent.Runner.Tree`).
  """
  @behaviour ForemanAgent.Runner

  alias ForemanAgent.Runner.{Collector, Tree}

  @default_keep 65_536
  # How long a timed-out command gets to exit after SIGTERM.
  @grace 5_000

  @impl true
  def run(command, args, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, {:not_found, command}}

      path ->
        keep = Keyword.get(opts, :keep, @default_keep)
        on_output = Keyword.get(opts, :on_output, fn _ -> :ok end)

        cmd_opts =
          [
            env: child_env(Keyword.get(opts, :env, %{})),
            stderr_to_stdout: true,
            into: %Collector{keep: keep, on_output: on_output}
          ] ++ Keyword.take(opts, [:cd])

        {collector, status} =
          with_timeout(opts[:timeout], fn -> MuonTrap.cmd(path, args, cmd_opts) end)

        {:ok, %{status: status, output: Collector.output(collector)}}
    end
  end

  # MuonTrap's own timeout only kills the direct child, so a watchdog
  # takes the tree down instead; the command then returns on its own.
  defp with_timeout(nil, fun), do: fun.()

  defp with_timeout(timeout, fun) do
    caller = self()
    ref = make_ref()

    {watchdog, monitor} =
      spawn_monitor(fn ->
        caller_monitor = Process.monitor(caller)

        receive do
          ^ref -> :ok
          {:DOWN, ^caller_monitor, _, _, _} -> :ok
        after
          timeout ->
            send(caller, {ref, :timed_out})
            Tree.terminate(Tree.os_pids(caller), @grace)
        end
      end)

    {collector, status} =
      try do
        fun.()
      after
        send(watchdog, ref)
      end

    receive do
      {^ref, :timed_out} ->
        # Let the watchdog finish off the rest of the tree first.
        receive do
          {:DOWN, ^monitor, _, _, _} -> :ok
        after
          @grace * 3 -> :ok
        end

        {collector, :timeout}
    after
      0 ->
        Process.demonitor(monitor, [:flush])
        {collector, status}
    end
  end

  @base ~w(PATH HOME LANG LC_ALL TZ DOCKER_HOST SSL_CERT_FILE SSL_CERT_DIR
           HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy)

  @doc false
  # Unsets everything inherited except a small base, then applies `env`.
  def child_env(env) do
    inherited = System.get_env()
    unset = for {k, _} <- inherited, k not in @base, not Map.has_key?(env, k), do: {k, nil}

    base = %{
      "LANG" => inherited["LANG"] || "C.UTF-8",
      "NO_COLOR" => "1",
      "GIT_TERMINAL_PROMPT" => "0"
    }

    unset ++ Enum.to_list(Map.merge(base, env))
  end
end
