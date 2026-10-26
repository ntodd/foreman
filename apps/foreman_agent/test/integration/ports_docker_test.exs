defmodule ForemanAgent.Integration.PortsDockerTest do
  @moduledoc """
  Reads listening ports and their processes from real containers, through
  the real Engine API and the box's /proc. It needs what an agent on a box
  has: Linux, and Docker's processes in its own pid namespace. Elsewhere
  Docker runs in a VM, or (on CI's runners) the tests run in a container
  of their own, and neither can see the containers' pids. Run on a Linux
  host with:

      mix test --only host_pids

  CI covers the same path through e2e/linux/run.sh, where the agent runs
  on a box with its own Docker.
  """
  use ExUnit.Case, async: false

  alias ForemanAgent.{Config, Ports}
  alias ForemanAgent.Docker.Engine

  @moduletag :host_pids
  @moduletag timeout: 300_000

  unless match?({:unix, :linux}, :os.type()),
    do: @moduletag(skip: "Docker's /proc is only the box's on Linux")

  @run Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  @env1 "#{@run}11-1111-4111-8111-111111111111"
  @env2 "#{@run}22-2222-4222-8222-222222222222"
  @image "alpine:3.22"

  setup_all do
    previous = Config.get()
    Config.put(%{previous | docker_socket: docker_socket()})

    on_exit(fn ->
      {ids, 0} = docker(["ps", "-aq", "--filter", "label=foreman.ports-test=#{@run}"])
      for id <- String.split(ids, "\n", trim: true), do: docker(["rm", "-f", id])
      Config.put(previous)
    end)
  end

  defp docker_socket do
    case System.get_env("DOCKER_HOST") do
      "unix://" <> path -> path
      _ -> "/var/run/docker.sock"
    end
  end

  defp docker(args) do
    System.cmd("docker", args,
      stderr_to_stdout: true,
      env: [{"DOCKER_HOST", "unix://" <> Config.get().docker_socket}]
    )
  end

  defp uid_gid do
    {uid, 0} = System.cmd("id", ["-u"])
    {gid, 0} = System.cmd("id", ["-g"])
    {String.trim(uid), String.trim(gid)}
  end

  # A running container labelled like an environment's, as the agent's
  # uid and gid: what the devcontainer CLI does with the remote user.
  defp start(env_id, opts \\ []) do
    {uid, gid} = uid_gid()
    devcontainer = if Keyword.get(opts, :devcontainer, true), do: "true", else: ""

    {id, 0} =
      docker([
        "run",
        "-d",
        "--label",
        "foreman.ports-test=#{@run}",
        "--label",
        "foreman.env_id=#{env_id}",
        "--label",
        "foreman.slug=ports-#{@run}",
        "--label",
        "foreman.devcontainer=#{devcontainer}",
        "-u",
        "#{uid}:#{gid}",
        @image,
        "sleep",
        "600"
      ])

    String.trim(id)
  end

  defp listen(id, user, script) do
    {_, 0} = docker(["exec", "-d", "-u", user, id, "sh", "-c", script])
  end

  defp ctx, do: Map.put(ForemanAgent.Handler.ctx(fn _, _ -> :ok end), :docker, Engine)

  # Listeners come up asynchronously after `docker exec -d`.
  defp eventually(fun, tries \\ 50) do
    case fun.() do
      {:ok, value} ->
        value

      {:retry, _last} when tries > 1 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      {:retry, last} ->
        flunk("never settled; last: #{inspect(last)}")
    end
  end

  defp collect_until(expected_ports, cache \\ %{}) do
    eventually(fn ->
      {report, cache} = Ports.collect(ctx(), cache)
      ports = report |> Map.get(@env1, []) |> Enum.map(& &1.port)
      if ports == expected_ports, do: {:ok, {report, cache}}, else: {:retry, report}
    end)
  end

  test "reports a devcontainer's reachable ports, named when they're the agent's uid's" do
    {uid, gid} = uid_gid()
    # The gid too: the kernel only shows a process's fds to the same uid
    # and gid, and `docker exec -u <uid>` alone runs as gid 0.
    user = "#{uid}:#{gid}"
    app = start(@env1)
    # Another service of the same environment, and another environment.
    sidecar = start(@env1, devcontainer: false)
    other = start(@env2)

    listen(app, user, "nc -lk -p 4000 -e true")
    listen(app, user, "nc -lk -s 127.0.0.1 -p 5000 -e true")
    # Not reachable: tailscaled's outbound proxy, and the compose network.
    listen(app, user, "nc -lk -s 127.0.0.2 -p 1055 -e true")
    listen(app, user, "nc -lk -s $(hostname -i) -p 7000 -e true")
    # Root's: its fds aren't readable from the box unless the agent is root.
    listen(app, "0", "nc -lk -p 6000 -e true")
    listen(sidecar, user, "nc -lk -p 9000 -e true")

    {report, cache} = collect_until([4000, 5000, 6000])

    root_listener = if uid == "0", do: %{port: 6000, process: "nc"}, else: %{port: 6000}

    assert report[@env1] == [
             %{port: 4000, process: "nc"},
             %{port: 5000, process: "nc"},
             root_listener
           ]

    assert report[@env2] == []
    assert {:ok, _} = ForemanProtocol.Event.new("box.ports", %{environments: report})

    # A server stopping and another starting.
    {_, 0} = docker(["exec", "-u", "0", app, "pkill", "-f", "p 5000"])
    listen(other, user, "nc -lk -p 8080 -e true")

    {report, cache} = collect_until([4000, 6000], cache)

    eventually(fn ->
      {report, _} = Ports.collect(ctx(), cache)

      if report[@env2] == [%{port: 8080, process: "nc"}],
        do: {:ok, report},
        else: {:retry, report}
    end)

    assert Enum.map(report[@env1], & &1.port) == [4000, 6000]

    # A stopped environment is left out.
    {_, 0} = docker(["stop", "-t", "0", other])

    eventually(fn ->
      {report, _} = Ports.collect(ctx(), cache)
      if Map.has_key?(report, @env2), do: {:retry, report}, else: {:ok, report}
    end)
  end

  test "Engine.top lists a container's host pids" do
    id = start(@env1)
    {:ok, %{"State" => %{"Pid" => init}}} = Engine.inspect_container(id)
    assert {:ok, pids} = Engine.top(id)
    assert init in pids
    assert {:error, :invalid_id} = Engine.top("../containers")
    assert {:error, _} = Engine.top("0123456789ab")
  end
end
