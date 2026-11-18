defmodule ForemanAgent.Guest.Reclaim do
  @moduledoc """
  Gives the box back memory the guest's page cache holds, when the box
  asks (the `reclaim` query, see `ForemanAgent.Channel`).

  A VM only takes the box memory its guest touches, and the balloon's free
  page reporting hands back what the guest frees, but page cache isn't
  free as far as the guest is concerned. So the guest reclaims its file
  LRU (`Active(file)` + `Inactive(file)`) down to what the box says to
  keep, coldest pages first, through `memory.reclaim` at its root cgroup,
  then compacts its memory: free page reporting only reports free blocks
  of 2 MiB or more. See issue #200 for the measurements.

  Then it drains the per-CPU free lists and compacts again. A big reclaim
  leaves free pages on them, a few to a 2 MiB block, which keeps those
  blocks from coalescing, and since kernel 6.7 the lists only shrink from
  per-CPU work idle CPUs don't do. #203's run on the production box found
  about 100 MiB of them holding back some 1,400 blocks. The drain sets
  `vm.percpu_pagelist_high_fraction` high, which lowers every list's high
  mark, runs that work on every CPU through `stat_refresh` until the lists
  come down to it, compacts, and puts the fraction back as it was. A drain
  that fails leaves the reclaim standing.

  The files need root, and the agent has no capabilities for them, so a
  root helper in the guest image does the writes: `foreman-guest-reclaim`,
  socket-activated on `/run/foreman-reclaim.sock` (root and the agent's
  group), one request line (the bytes to reclaim) and one answer line. A
  VM whose root disk was made from an older image has no helper, and says
  so (`unsupported/0`).

  The guest is untrusted, so this is cooperative: nothing on the box
  counts on it having happened. One reclaim runs at a time; the host
  giving up on one doesn't stop it.
  """

  require Logger

  @helper "/run/foreman-reclaim.sock"
  # Past this, the helper's unit stops it (RuntimeMaxSec=45).
  @timeout 50_000
  # Less than this past what to keep isn't worth a compaction.
  @min_request 64 * 1_048_576
  @max_keep_mb 1_048_576

  @unsupported "this VM's system image can't reclaim memory"

  @answer ~r/\Aok reclaim=(ok|partial|failed) compact=(ok|failed) drain=(ok|failed) reclaim_ms=(\d{1,9}) compact_ms=(\d{1,9}) drain_ms=(\d{1,9})\n?\z/

  @doc "The error a guest without the helper answers with."
  def unsupported, do: @unsupported

  @doc """
  Reclaims the guest's page cache past `"keep_mb"` MiB, compacts, and
  drains the per-CPU free lists, and reports the page cache and free
  memory before and after (MiB), what each step did and how long it took
  (ms).

  Options: `:proc` (default `/proc`), `:helper` (the helper's socket) and
  `:timeout` (milliseconds to wait for the helper).
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(args, opts \\ [])

  def run(%{"keep_mb" => keep_mb}, opts)
      when is_integer(keep_mb) and keep_mb in 0..@max_keep_mb do
    lock = {__MODULE__, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        reclaim(keep_mb, opts)
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, "a reclaim is already running"}
    end
  end

  def run(_args, _opts),
    do: {:error, "keep_mb must be a whole number of MiB up to #{@max_keep_mb}"}

  defp reclaim(keep_mb, opts) do
    proc = Keyword.get(opts, :proc, "/proc")

    with {:ok, before} <- memory(proc) do
      request = before.file - keep_mb * 1_048_576

      if request < @min_request do
        skipped = %{reclaim: "skipped", compact: "skipped", drain: "skipped", ms: {0, 0, 0}}
        {:ok, result(before, before, 0, skipped)}
      else
        with {:ok, done} <- ask(request, opts),
             {:ok, later} <- memory(proc) do
          {:ok, result(before, later, request, done)}
        end
      end
    end
  end

  defp result(before, later, request, done) do
    {reclaim_ms, compact_ms, drain_ms} = done.ms

    %{
      "requested_mb" => mb(request),
      "file_before_mb" => mb(before.file),
      "file_after_mb" => mb(later.file),
      "free_before_mb" => mb(before.free),
      "free_after_mb" => mb(later.free),
      "reclaim" => done.reclaim,
      "compact" => done.compact,
      "drain" => done.drain,
      "reclaim_ms" => reclaim_ms,
      "compact_ms" => compact_ms,
      "drain_ms" => drain_ms
    }
  end

  defp mb(bytes), do: div(bytes, 1_048_576)

  # Bytes of file LRU and free memory.
  defp memory(proc) do
    case File.read(Path.join(proc, "meminfo")) do
      {:ok, text} ->
        kb = fn key ->
          case Regex.run(~r/^#{Regex.escape(key)}:\s+(\d+) kB$/m, text) do
            [_, n] -> String.to_integer(n) * 1024
            nil -> nil
          end
        end

        case {kb.("Active(file)"), kb.("Inactive(file)"), kb.("MemFree")} do
          {active, inactive, free}
          when is_integer(active) and is_integer(inactive) and is_integer(free) ->
            {:ok, %{file: active + inactive, free: free}}

          _ ->
            {:error, "couldn't read the guest's memory: meminfo is missing a field"}
        end

      {:error, reason} ->
        {:error, "couldn't read the guest's memory: #{:file.format_error(reason)}"}
    end
  end

  # The helper reads to the end of the request, so the write side closes
  # once it's sent.
  defp ask(request, opts) do
    path = Keyword.get(opts, :helper, @helper)
    timeout = Keyword.get(opts, :timeout, @timeout)
    socket_opts = [:binary, active: false, packet: :line, buffer: 1024]

    case :gen_tcp.connect({:local, path}, 0, socket_opts, 5_000) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, "#{request}\n"),
               :ok <- :gen_tcp.shutdown(socket, :write),
               {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
            answer(line)
          else
            {:error, :timeout} -> {:error, "the reclaim helper didn't answer in time"}
            {:error, reason} -> {:error, "the reclaim helper failed: #{inspect(reason)}"}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        {:error, @unsupported}

      {:error, reason} ->
        {:error, "couldn't reach the reclaim helper: #{inspect(reason)}"}
    end
  end

  defp answer("error " <> message),
    do: {:error, "the reclaim helper refused: #{String.trim_trailing(message)}"}

  defp answer(line) do
    case Regex.run(@answer, line) do
      [_, reclaim, compact, drain, reclaim_ms, compact_ms, drain_ms] ->
        if reclaim != "ok" or compact != "ok" or drain != "ok",
          do: Logger.info("reclaim: #{String.trim_trailing(line)}")

        {:ok,
         %{
           reclaim: reclaim,
           compact: compact,
           drain: drain,
           ms:
             {String.to_integer(reclaim_ms), String.to_integer(compact_ms),
              String.to_integer(drain_ms)}
         }}

      nil ->
        {:error, "the reclaim helper answered something else"}
    end
  end
end
