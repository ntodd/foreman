defmodule ForemanAgent.Test.VsockBridge do
  @moduledoc """
  Stands in for Cloud Hypervisor's hybrid vsock in tests: listens on a
  unix socket, takes `CONNECT <port>\\n`, connects to `target` (the guest
  agent's socket), answers `OK <port>\\n` and copies bytes both ways.

  `drop/1` closes every connection (a lost link); `stop/1` closes the
  listener too (the VM gone).
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def drop(bridge), do: GenServer.call(bridge, :drop)
  def stop(bridge), do: GenServer.stop(bridge)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    _ = File.rm(path)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false])
    bridge = self()
    acceptor = spawn_link(fn -> accept(listen, bridge, Keyword.fetch!(opts, :target)) end)
    {:ok, %{listen: listen, path: path, acceptor: acceptor, pipes: []}}
  end

  @impl true
  def handle_call(:drop, _from, state) do
    Enum.each(state.pipes, &Process.exit(&1, :kill))
    {:reply, :ok, %{state | pipes: []}}
  end

  @impl true
  def handle_info({:pipe, pid}, state), do: {:noreply, %{state | pipes: [pid | state.pipes]}}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pipes, &Process.exit(&1, :kill))
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end

  defp accept(listen, bridge, target) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        pid = spawn(fn -> pipe(client, target) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        send(bridge, {:pipe, pid})
        accept(listen, bridge, target)

      {:error, _} ->
        :ok
    end
  end

  defp pipe(client, target) do
    receive do
      :go -> :ok
    end

    :ok = :inet.setopts(client, packet: :line)

    with {:ok, "CONNECT " <> port} <- :gen_tcp.recv(client, 0, 5_000),
         {:ok, guest} <- :gen_tcp.connect({:local, target}, 0, [:binary, active: true]) do
      :ok = :gen_tcp.send(client, "OK " <> port)
      :ok = :inet.setopts(client, packet: :raw, active: true)
      copy(client, guest)
    else
      _ -> :gen_tcp.close(client)
    end
  end

  defp copy(client, guest) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(guest, data)
        copy(client, guest)

      {:tcp, ^guest, data} ->
        :gen_tcp.send(client, data)
        copy(client, guest)

      {:tcp_closed, _} ->
        :gen_tcp.close(client)
        :gen_tcp.close(guest)
    end
  end
end
