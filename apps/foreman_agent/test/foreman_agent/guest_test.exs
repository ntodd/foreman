defmodule ForemanAgent.GuestTest do
  # configure/1 changes the cached config, so not async.
  use ExUnit.Case, async: false

  import Mox

  alias ForemanAgent.{Config, DockerMock, Guest}

  @tag :tmp_dir
  test "port polls share names across query tasks until the guest session ends", %{tmp_dir: proc} do
    saved = Config.get()
    docker = Application.fetch_env(:foreman_agent, :docker)

    on_exit(fn ->
      Config.put(saved)

      case docker do
        {:ok, impl} -> Application.put_env(:foreman_agent, :docker, impl)
        :error -> Application.delete_env(:foreman_agent, :docker)
      end
    end)

    Config.put(%{saved | proc: proc})
    Application.put_env(:foreman_agent, :docker, DockerMock)
    id = "aaa111aaa111"
    env = ForemanProtocol.uuid()
    labels = %{"foreman.env_id" => env, "foreman.devcontainer" => "true"}
    container = %{"Id" => id, "State" => "running", "Labels" => labels}
    stub(DockerMock, :list_containers, fn _ -> {:ok, [container]} end)
    stub(DockerMock, :inspect_container, fn ^id -> {:ok, %{"State" => %{"Pid" => 7}}} end)
    File.mkdir_p!(Path.join(proc, "7/net"))
    File.write!(Path.join(proc, "7/net/tcp"), "0: 00000000:0FA0 0 0A 0 0 0 1000 0 1\n")

    # An unnamed listener is cached too. Reconnecting must do a fresh lookup.
    expect(DockerMock, :top, 2, fn ^id -> {:ok, []} end)
    first = Guest.queries()["ports"]
    second = Guest.queries()["ports"]

    for poll <- [first, first, second] do
      assert {:ok, %{^env => [%{"port" => 4000}]}} = poll |> Task.async() |> Task.await()
    end

    verify!()
  end

  describe "sync_clock/2" do
    test "leaves a clock within two seconds alone" do
      now = System.os_time(:millisecond)
      assert :ok = Guest.sync_clock(now + 1_500, fn _ -> flunk("stepped") end)
      assert :ok = Guest.sync_clock(now - 1_500, fn _ -> flunk("stepped") end)
    end

    test "steps a clock that's behind or ahead to the host's" do
      test = self()
      host = System.os_time(:millisecond) + 25_000
      assert :stepped = Guest.sync_clock(host, &send(test, {:set, &1}))
      assert_received {:set, ^host}

      host = System.os_time(:millisecond) - 60_000
      assert :stepped = Guest.sync_clock(host, &send(test, {:set, &1}))
      assert_received {:set, ^host}
    end
  end

  describe "configure/1" do
    setup do
      saved = Config.get()
      on_exit(fn -> Config.put(saved) end)
      Config.put(%{saved | allowed_git_hosts: ["github.com"], insecure_git_hosts: []})
      :ok
    end

    test "takes the box's clone hosts" do
      Guest.configure(%{
        "allowed_git_hosts" => ["github.com", "git.example.com:8443"],
        "insecure_git_hosts" => ["10.0.0.5"]
      })

      assert Config.get().allowed_git_hosts == ["github.com", "git.example.com:8443"]
      assert Config.get().insecure_git_hosts == ["10.0.0.5"]
    end

    test "keeps what it had when the list is malformed" do
      Guest.configure(%{"allowed_git_hosts" => ["github.com", "evil host; rm -rf /"]})
      Guest.configure(%{"allowed_git_hosts" => "github.com"})
      Guest.configure(%{"insecure_git_hosts" => List.duplicate("a.example", 101)})

      assert Config.get().allowed_git_hosts == ["github.com"]
      assert Config.get().insecure_git_hosts == []
    end
  end
end
