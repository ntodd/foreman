defmodule ForemanAgent.Guest.Server do
  @moduledoc """
  The guest agent's end of `ForemanAgent.Channel`.

  Listens on a unix socket, which `socat` joins to vsock port 1024 in the
  guest, and serves one host connection at a time in a
  `ForemanAgent.Guest.Session`. A new connection replaces the one before
  it: the host only reconnects when the old one is gone (or it restarted
  without noticing), and the newest is the one it's listening on.

  Options:

    * `:path` - the socket (default: the config's `guest_socket`)
    * `:session` - options for each session (see `ForemanAgent.Guest.Session`)
  """
  use GenServer

  alias ForemanAgent.Guest.Session

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Asks the box, over the connection it has to this guest, to relay a
  public API request (see `ForemanAgent.Guest.Session.request/3`).
  """
  @spec request(GenServer.server(), map()) :: {:ok, map()} | {:error, atom()}
  def request(server \\ __MODULE__, request) do
    case GenServer.call(server, :session) do
      nil -> {:error, :not_connected}
      connection -> Session.request(connection, request)
    end
  catch
    :exit, _ -> {:error, :not_connected}
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, fn -> ForemanAgent.Config.get().guest_socket end)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    # Only root (socat, in the guest) connects.
    File.chmod!(dir, 0o700)
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false, backlog: 4])

    server = self()
    acceptor = spawn_link(fn -> accept_loop(listen, server) end)

    {:ok,
     %{
       listen: listen,
       acceptor: acceptor,
       session: nil,
       budget: nil,
       session_opts: Keyword.get(opts, :session, [])
     }}
  end

  @impl true
  def handle_call({:accepted, socket}, _from, state) do
    if state.session, do: Session.close(state.session)

    # A new connection starts with nothing reserved: what the old one's
    # requests held went with it.
    budget = Session.budget()
    {:ok, pid} = Session.start(socket, Keyword.put(state.session_opts, :budget, budget))
    Process.monitor(pid)
    {:reply, {:ok, pid}, %{state | session: pid, budget: budget}}
  end

  def handle_call(:session, _from, %{session: nil} = state), do: {:reply, nil, state}
  def handle_call(:session, _from, state), do: {:reply, {state.session, state.budget}, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{session: pid} = state),
    do: {:noreply, %{state | session: nil}}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} = GenServer.call(server, {:accepted, socket})
        :ok = :gen_tcp.controlling_process(socket, pid)
        Session.go(pid)
        accept_loop(listen, server)

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end
end
