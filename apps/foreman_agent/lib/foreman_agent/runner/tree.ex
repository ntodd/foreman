defmodule ForemanAgent.Runner.Tree do
  @moduledoc """
  Kills the processes a command started, all the way down.

  MuonTrap kills its direct child when its port closes, but without cgroups
  that's all: the devcontainer CLI's `docker compose up`, or git's
  `git-remote-https`, would keep running after a cancel or a timeout and
  race the next operation. This finds every descendant of the MuonTrap
  processes an Erlang process owns, asks them to stop, and kills whatever
  is left after a grace period.

  A process that left the tree (a daemon that double-forked to init) isn't
  found. Catching those too would take a cgroup per command, which needs
  the agent's VM moved into a leaf cgroup of a delegated subtree.
  """

  require Logger

  @poll 100

  @doc "OS pids of the external programs (ports) `pid` owns."
  @spec os_pids(pid()) :: [non_neg_integer()]
  def os_pids(pid) do
    for port <- Port.list(),
        Port.info(port, :connected) == {:connected, pid},
        {:os_pid, os_pid} <- [Port.info(port, :os_pid)],
        do: os_pid
  end

  @doc """
  Sends SIGTERM to every descendant of `roots`, waits up to `grace`
  milliseconds for them to exit, then SIGKILLs the rest. The roots
  themselves (MuonTrap) exit once their child has.
  """
  @spec terminate([non_neg_integer()], non_neg_integer()) :: :ok
  def terminate([], _grace), do: :ok

  def terminate(roots, grace) do
    table = processes()

    case descendants(roots, table) do
      [] ->
        :ok

      pids ->
        signal(pids, "TERM")
        survivors = wait(roots, pids, grace)
        kill(roots, survivors, 20)
    end
  end

  # Waits for the tree to exit; returns what's still alive when time is up.
  defp wait(roots, known, remaining) do
    table = processes()
    alive = alive(roots, known, table)

    cond do
      alive == [] ->
        []

      remaining <= 0 ->
        alive

      true ->
        Process.sleep(@poll)
        wait(roots, Enum.uniq(known ++ alive), remaining - @poll)
    end
  end

  # SIGKILLs repeatedly: a process can fork between one scan and the next.
  defp kill(_roots, [], _tries), do: :ok

  defp kill(_roots, pids, 0) do
    Logger.warning("couldn't kill processes #{inspect(pids)}")
    :ok
  end

  defp kill(roots, pids, tries) do
    signal(pids, "KILL")
    Process.sleep(@poll)
    kill(roots, alive(roots, pids, processes()), tries - 1)
  end

  # Known pids still running, plus any new descendants of the roots.
  defp alive(roots, known, table) do
    Enum.uniq(Enum.filter(known, &Map.has_key?(table, &1)) ++ descendants(roots, table))
  end

  @doc false
  # Every descendant of `roots` in `table` (pid => ppid), roots excluded.
  def descendants(roots, table) do
    children = Enum.group_by(table, fn {_pid, ppid} -> ppid end, fn {pid, _} -> pid end)
    walk(roots, children, [])
  end

  defp walk([], _children, acc), do: acc

  defp walk([pid | rest], children, acc) do
    kids = Map.get(children, pid, []) -- acc
    walk(kids ++ rest, children, acc ++ kids)
  end

  defp signal(pids, sig) do
    args = Enum.map(pids, &Integer.to_string/1)
    # The shell's kill builtin: there may be no kill binary on the box.
    System.cmd("sh", ["-c", "kill -s #{sig} \"$@\" 2>/dev/null; true", "kill" | args])
    :ok
  end

  @doc false
  # Running processes as pid => ppid, zombies left out.
  def processes do
    case :os.type() do
      {:unix, :linux} -> proc_processes()
      _ -> ps_processes()
    end
  end

  defp proc_processes do
    "/proc"
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      with {pid, ""} <- Integer.parse(name),
           {:ok, stat} <- File.read("/proc/#{name}/stat"),
           {state, ppid} <- parse_stat(stat),
           true <- state != "Z" do
        [{pid, ppid}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  # "pid (comm) state ppid ...": comm can hold spaces and parentheses.
  defp parse_stat(stat) do
    with [_, rest] <- :binary.split(stat, ")", [:global]) |> split_last(),
         [state, ppid | _] <- String.split(rest),
         {ppid, ""} <- Integer.parse(ppid) do
      {state, ppid}
    else
      _ -> nil
    end
  end

  defp split_last(parts) when length(parts) >= 2,
    do: [Enum.join(Enum.drop(parts, -1), ")"), List.last(parts)]

  defp split_last(_), do: nil

  defp ps_processes do
    case System.cmd("ps", ["-A", "-o", "pid=", "-o", "ppid=", "-o", "stat="]) do
      {output, 0} ->
        for line <- String.split(output, "\n", trim: true),
            [pid, ppid, stat | _] <- [String.split(line)],
            not String.starts_with?(stat, "Z"),
            {pid, ""} <- [Integer.parse(pid)],
            {ppid, ""} <- [Integer.parse(ppid)],
            into: %{},
            do: {pid, ppid}

      _ ->
        %{}
    end
  end
end
