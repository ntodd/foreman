defmodule ForemanAgent.GuestTest do
  # configure/1 changes the cached config, so not async.
  use ExUnit.Case, async: false

  alias ForemanAgent.{Config, Guest}

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
