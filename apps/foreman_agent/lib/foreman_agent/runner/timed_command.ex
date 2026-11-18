defmodule ForemanAgent.Runner.TimedCommand do
  @moduledoc false
  alias ForemanAgent.Runner.Tree

  @grace 5_000
  @retry 50

  # Keep the port in the operation process so Ops can still cancel it.
  # The watchdog follows this specific port from startup through exit.
  def open(command, args, opts) do
    options = MuonTrap.Options.validate(:cmd, command, args, opts)
    port_opts = MuonTrap.Port.port_options(options, ["--capture-output"])
    Port.open({:spawn_executable, MuonTrap.muontrap_path()}, port_opts)
  end

  def await(port, collector, timeout) do
    {acc, collect} = Collectable.into(collector)
    deadline = System.monotonic_time(:millisecond) + timeout

    {_, monitor} =
      spawn_monitor(fn ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)
        exit(watch(port, Port.monitor(port), remaining))
      end)

    try do
      read(port, acc, collect, monitor)
    catch
      kind, reason ->
        Process.demonitor(monitor, [:flush])
        close(port)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp read(port, acc, collect, monitor) do
    receive do
      {^port, {:data, data}} ->
        MuonTrap.Port.report_bytes_handled(port, byte_size(data))
        read(port, collect.(acc, {:cont, data}), collect, monitor)

      {^port, {:exit_status, status}} ->
        {collect.(acc, :done), exit_status(monitor, status)}

      {:EXIT, ^port, reason} when reason != :normal ->
        :erlang.error(reason)

      {:DOWN, ^monitor, :process, _, reason} when reason not in [:exited, :signalled] ->
        exit(reason)
    end
  end

  defp exit_status(monitor, status) do
    receive do
      {:DOWN, ^monitor, :process, _, :exited} -> status
      {:DOWN, ^monitor, :process, _, :signalled} -> :timeout
      {:DOWN, ^monitor, :process, _, reason} -> exit(reason)
    end
  end

  defp watch(port, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :port, ^port, _} -> :exited
    after
      timeout -> terminate(port, monitor)
    end
  end

  defp terminate(port, monitor) do
    with {:os_pid, root} <- Port.info(port, :os_pid),
         :signalled <- Tree.terminate([root], @grace) do
      :signalled
    else
      nil -> :exited
      # The helper may not have forked its child yet.
      :empty -> watch(port, monitor, @retry)
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
