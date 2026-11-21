defmodule ForemanAgent.VM.OomWatch do
  @moduledoc """
  The processes the kernel's OOM killer ended inside environment VMs.

  A VM that runs out of memory keeps running: its kernel kills something
  (a dev server, a language server, the guest agent itself) and carries
  on, and nothing on the box changes. The kernel says so on its console,
  at a level that `quiet` leaves on:

      Out of memory: Killed process 4321 (node) total-vm:...
      Memory cgroup out of memory: Killed process 777 (node) total-vm:...

  The box has each VM's console as `serial.log`, so it reads the kills
  there. That needs nothing from the guest, whose agent may be what was
  killed.

  The console is the guest's to write, and the file the VM's to replace.
  It's read through the VM file helper (never a link, at most the last
  64 KiB), and a name from it is the guest's word: anything that isn't a
  plain process name is dropped. A guest that writes the line itself
  only reports a kill in its own environment.
  """

  alias ForemanAgent.{Config, VM}
  alias ForemanAgent.Runner.Local

  @killed ~r/(?:Out of memory|Memory cgroup out of memory): Killed process \d+ \(([^\n]{1,64}?)\) total-vm:\d+kB/

  # Enough to say what happened. A VM out of memory can lose dozens.
  @max_names 8

  @typedoc "Where each VM's console was read to: the file it was, and the offset."
  @type cursors :: %{optional(String.t()) => {non_neg_integer(), non_neg_integer()}}

  @doc """
  The kills each VM's console gained since `cursors`, by environment, and
  the cursors for the next look. A console seen for the first time is
  read from its end: what it already holds happened before anyone was
  looking, and has no time to report.
  """
  @spec scan(Config.t(), cursors()) :: {%{optional(String.t()) => map()}, cursors()}
  def scan(config, cursors) do
    Enum.reduce(VM.list(config), {%{}, %{}}, fn env_id, {reports, next} ->
      path = VM.paths(config, env_id).serial

      case look(path, cursors[env_id]) do
        nil ->
          {reports, next}

        {cursor, []} ->
          {reports, Map.put(next, env_id, cursor)}

        {cursor, kills} ->
          {Map.put(reports, env_id, report(kills)), Map.put(next, env_id, cursor)}
      end
    end)
  end

  defp look(path, cursor) do
    case {File.lstat(path), cursor} do
      {{:ok, %{type: :regular, inode: inode, size: size}}, nil} ->
        {{inode, size}, []}

      {{:ok, %{type: :regular, inode: inode, size: size}}, {inode, size}} ->
        {cursor, []}

      {{:ok, %{type: :regular, inode: inode}}, {inode, offset}} ->
        read(path, inode, offset, cursor)

      # Another file in its place: a new console, from its beginning.
      {{:ok, %{type: :regular, inode: inode}}, _other} ->
        read(path, inode, 0, {inode, 0})

      _ ->
        nil
    end
  end

  defp read(path, inode, offset, fallback) do
    with {:ok, %{status: 0, output: output}} <-
           Local.run(VM.file_helper(), ["read-log", path, Integer.to_string(offset)],
             timeout: 5_000,
             keep: 131_072
           ),
         [next, lines] <- String.split(output, "\n", parts: 2),
         {next, ""} <- Integer.parse(next) do
      {{inode, next}, parse(lines)}
    else
      _ -> {fallback, []}
    end
  end

  defp report(kills) do
    %{processes: kills |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.take(@max_names)}
  end

  @doc """
  The kills in a stretch of console, oldest first: each the name (comm)
  of what was killed, or nil for a name that isn't fit to show.
  """
  @spec parse(binary()) :: [String.t() | nil]
  def parse(console) when is_binary(console) do
    for [_, comm] <- Regex.scan(@killed, console), do: name(comm)
  end

  # What the protocol takes as a process name.
  defp name(comm) do
    if String.valid?(comm) and not String.match?(comm, ~r/[[:cntrl:]]/u), do: comm
  end
end
