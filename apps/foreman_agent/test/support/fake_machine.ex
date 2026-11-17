defmodule ForemanAgent.Test.FakeMachine do
  @moduledoc """
  `ForemanAgent.VM.Machine` for tests: "booting" a VM starts a guest
  agent (Guest.Server, Ops and Outbox) in the test's own VM, behind a
  stand-in for Cloud Hypervisor's hybrid vsock at the VM's socket.

  What the guest does comes from `configure/1`: its `:handler` (Ops'
  handler, `fn cmd, log -> result end`) and `:queries`. With `boot: :hang`
  the guest never answers. Every call is reported to `:test` as
  `{:machine, call, env_id}`.
  """
  @behaviour ForemanAgent.VM.Machine

  alias ForemanAgent.Guest.Server
  alias ForemanAgent.{Ops, Outbox, VM}
  alias ForemanAgent.Test.VsockBridge

  @table __MODULE__

  def configure(opts) do
    ensure_table()
    :ets.insert(@table, {:opts, Map.new(opts)})
  end

  defp opts do
    ensure_table()

    case :ets.lookup(@table, :opts) do
      [{:opts, opts}] -> opts
      [] -> %{}
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      # Owned by a process that outlives any one test.
      owner =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      try do
        :ets.new(@table, [:named_table, :public, heir: owner, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp report(call, env_id) do
    if test = opts()[:test], do: send(test, {:machine, call, env_id})
  end

  @impl true
  def boot(env_id, spec, config) do
    report({:boot, spec}, env_id)

    case opts()[:boot] do
      :hang ->
        put(env_id, [])
        :ok

      {:error, message} ->
        {:error, message}

      _ ->
        paths = VM.paths(config, env_id)
        guest_socket = Path.join(paths.dir, "g.sock")
        handler = opts()[:handler] || fn _cmd, _log -> {:ok, %{}} end
        queries = opts()[:queries] || %{}

        {:ok, outbox} = Outbox.start_link(name: nil)
        {:ok, ops} = Ops.start_link(name: nil, handler: handler, sink: &Outbox.push(outbox, &1))

        session = [
          ops: ops,
          outbox: outbox,
          queries: queries,
          clock: fn _ -> :ok end,
          configure: fn _ -> :ok end
        ]

        {:ok, server} = Server.start_link(name: nil, path: guest_socket, session: session)
        {:ok, bridge} = VsockBridge.start_link(path: paths.vsock, target: guest_socket)

        for pid <- [outbox, ops, server, bridge], do: Process.unlink(pid)
        put(env_id, [bridge, server, ops, outbox])
        :ok
    end
  end

  @impl true
  def running?(env_id, _config) do
    ensure_table()
    :ets.lookup(@table, {:vm, env_id}) != []
  end

  # Like Cloud Hypervisor's: the guest's state (here, its processes) is
  # kept, and the VM stops. A restore picks the same guest back up.
  @impl true
  def snapshot(env_id, dir, _config) do
    report(:snapshot, env_id)

    case opts()[:snapshot] do
      {:error, message} ->
        {:error, message}

      _ ->
        [{_, [bridge | rest]}] = :ets.take(@table, {:vm, env_id})
        stop(bridge)
        File.write!(Path.join(dir, "config.json"), "{}")
        :ets.insert(@table, {{:suspended, env_id}, rest})
        :ok
    end
  end

  @impl true
  def restore(env_id, spec, config) do
    report({:restore, spec}, env_id)

    case {opts()[:restore], :ets.take(@table, {:suspended, env_id})} do
      {{:error, message}, _} ->
        {:error, message}

      # Like Cloud Hypervisor under the helper's unit: the request returns
      # at once, and the VM reads its snapshot after; one that's gone by
      # then never comes back.
      {_, [{_, pids}]} ->
        paths = VM.paths(config, env_id)
        guest_socket = Path.join(paths.dir, "g.sock")

        spawn(fn ->
          Process.sleep(30)

          if File.regular?(Path.join(paths.snapshot, "config.json")) do
            {:ok, bridge} = VsockBridge.start_link(path: paths.vsock, target: guest_socket)
            Process.unlink(bridge)
            put(env_id, [bridge | pids])
          else
            report(:restore_lost_its_snapshot, env_id)
            Enum.each(pids, &stop/1)
          end
        end)

        put(env_id, [])
        :ok

      {_, []} ->
        {:error, "nothing to restore"}
    end
  end

  @impl true
  def unpause(env_id, _config) do
    report(:unpause, env_id)
    :ok
  end

  @impl true
  def power_off(env_id, _timeout, config) do
    report(:power_off, env_id)
    kill(env_id, config)
  end

  @impl true
  def kill(env_id, _config) do
    ensure_table()

    for key <- [{:vm, env_id}, {:suspended, env_id}],
        {_, pids} <- :ets.take(@table, key),
        do: Enum.each(pids, &stop/1)

    :ok
  end

  @impl true
  def release(env_id, config) do
    report(:release, env_id)
    kill(env_id, config)
  end

  @impl true
  def usage(env_ids, _config) do
    for env_id <- env_ids, running?(env_id, nil), into: %{} do
      {env_id, %{cpu_usec: System.monotonic_time(:microsecond), memory_bytes: 512 * 1_048_576}}
    end
  end

  defp put(env_id, pids) do
    ensure_table()
    :ets.insert(@table, {{:vm, env_id}, pids})
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end
end
