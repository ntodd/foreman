defmodule ForemanAgent.UpdaterResendTest do
  # The control plane can send the same update twice: once per connect while
  # the box's version differs from the desired one.
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, Updater}
  alias ForemanProtocol.Auth

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {public, private} = Auth.generate_keypair()

    src = Path.join(tmp, "src")
    File.mkdir_p!(Path.join(src, "bin"))
    File.write!(Path.join(src, "bin/foreman_agent"), "#!/bin/sh\necho new\n")
    tarball = Path.join(tmp, "release.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tarball),
        [{~c"bin/foreman_agent", String.to_charlist(Path.join(src, "bin/foreman_agent"))}],
        [:compressed]
      )

    body = File.read!(tarball)
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    config = %Config{release_root: Path.join(tmp, "opt"), release_public_key: public}
    File.mkdir_p!(Path.join(config.release_root, "releases/0.1.0"))
    File.ln_s!("releases/0.1.0", Path.join(config.release_root, "current"))

    %{config: config, private: private, sha: sha, body: body}
  end

  defp payload(version, sha, private) do
    target = Updater.target()

    %{
      version: version,
      url: "https://foreman.example/agent/releases/#{version}/#{target}",
      sha256: sha,
      signature: Auth.sign_release(version, target, sha, private)
    }
  end

  defp link(config, name) do
    case :file.read_link(String.to_charlist(Path.join(config.release_root, name))) do
      {:ok, target} -> to_string(target)
      {:error, reason} -> reason
    end
  end

  defp stub_download(name, body, fun \\ fn -> :ok end) do
    Req.Test.stub(name, fn conn ->
      fun.()
      Plug.Conn.send_resp(conn, 200, body)
    end)

    [req_options: [plug: {Req.Test, name}]]
  end

  test "a repeated update is a no-op that keeps the rollback target", c do
    opts = stub_download(__MODULE__.Repeat, c.body)
    p = payload("0.2.0", c.sha, c.private)

    assert {:ok, %{"restart" => true}} = Updater.run(p, c.config, fn _, _ -> :ok end, opts)
    assert {:ok, _} = Updater.run(p, c.config, fn _, _ -> :ok end, opts)

    assert link(c.config, "current") == "releases/0.2.0"
    assert link(c.config, "previous") == "releases/0.1.0"
  end

  test "overlapping updates to the same version run one after the other", c do
    test_pid = self()
    counter = :counters.new(1, [])

    opts =
      stub_download(__MODULE__.Overlap, c.body, fn ->
        :counters.add(counter, 1, 1)
        send(test_pid, :downloading)
        Process.sleep(300)
      end)

    p = payload("0.2.0", c.sha, c.private)
    run = fn -> Updater.run(p, c.config, fn _, _ -> :ok end, opts) end

    first = Task.async(run)
    Req.Test.allow(__MODULE__.Overlap, self(), first.pid)
    assert_receive :downloading
    second = Task.async(run)
    Req.Test.allow(__MODULE__.Overlap, self(), second.pid)

    assert [{:ok, _}, {:ok, _}] = Task.await_many([first, second], 30_000)
    assert :counters.get(counter, 1) == 1, "the second update downloaded again"
    assert link(c.config, "current") == "releases/0.2.0"
    assert link(c.config, "previous") == "releases/0.1.0"
  end

  test "an update leaves only the current and previous releases, and no downloads", c do
    File.mkdir_p!(Path.join(c.config.release_root, "releases/0.0.9"))
    File.mkdir_p!(Path.join(c.config.release_root, "downloads"))
    File.write!(Path.join(c.config.release_root, "downloads/0.1.5-stale.tar.gz"), "partial")

    opts = stub_download(__MODULE__.Prune, c.body)

    assert {:ok, _} =
             Updater.run(payload("0.2.0", c.sha, c.private), c.config, fn _, _ -> :ok end, opts)

    assert c.config.release_root |> Path.join("releases") |> File.ls!() |> Enum.sort() ==
             ["0.1.0", "0.2.0"]

    assert c.config.release_root |> Path.join("downloads") |> File.ls!() == []
  end

  describe "confirming a release" do
    test "clears the rollback target once the new release has joined", c do
      opts = stub_download(__MODULE__.Confirm, c.body)

      assert {:ok, _} =
               Updater.run(payload("0.2.0", c.sha, c.private), c.config, fn _, _ -> :ok end, opts)

      assert :ok = Updater.confirm(c.config, "0.2.0")
      assert link(c.config, "previous") == :enoent
      assert link(c.config, "current") == "releases/0.2.0"
      now = System.system_time(:second)
      refute Updater.rollback_due?(c.config, now, now + 3_600, "0.2.0")
    end

    test "is a no-op without an update" do
      assert :ok = Updater.confirm(%Config{release_root: "/nonexistent/foreman-agent"})
    end
  end

  describe "a release that never joins" do
    test "is rolled back once the grace period has passed", c do
      opts = stub_download(__MODULE__.Rollback, c.body)

      assert {:ok, _} =
               Updater.run(payload("0.2.0", c.sha, c.private), c.config, fn _, _ -> :ok end, opts)

      now = System.system_time(:second)
      refute Updater.rollback_due?(c.config, now, now, "0.2.0")
      assert Updater.rollback_due?(c.config, now, now + 3_600, "0.2.0")

      assert :ok = Updater.rollback(c.config)
      assert link(c.config, "current") == "releases/0.1.0"
      assert link(c.config, "previous") == :enoent
      refute Updater.rollback_due?(c.config, now, now + 3_600, "0.1.0")
    end

    test "is timed from when this process started, not from the install", c do
      opts = stub_download(__MODULE__.SlowBoot, c.body)

      assert {:ok, _} =
               Updater.run(payload("0.2.0", c.sha, c.private), c.config, fn _, _ -> :ok end, opts)

      # The box was shut down right after the update and boots a day later;
      # the network takes a while to come up.
      booted = System.system_time(:second) + 86_400
      refute Updater.rollback_due?(c.config, booted, booted + 20, "0.2.0")
      refute Updater.rollback_due?(c.config, booted, booted + 299, "0.2.0")
      assert Updater.rollback_due?(c.config, booted, booted + 300, "0.2.0")
    end
  end

  describe "the old release, while it waits to restart into the new one" do
    # After installing, the old release keeps running until it's idle (up
    # to an hour). The rollback state belongs to the new release.

    test "doesn't confirm the update when it rejoins", c do
      opts = stub_download(__MODULE__.OldConfirm, c.body)

      assert {:ok, _} =
               Updater.run(payload("0.2.0", c.sha, c.private), c.config, fn _, _ -> :ok end, opts)

      assert :ok = Updater.confirm(c.config, "0.1.0")
      assert link(c.config, "previous") == "releases/0.1.0"
      assert File.exists?(Path.join(c.config.release_root, "update-pending"))
    end

    test "doesn't roll back the update when it's been disconnected a while", c do
      opts = stub_download(__MODULE__.OldWatchdog, c.body)

      assert {:ok, _} =
               Updater.run(payload("0.2.0", c.sha, c.private), c.config, fn _, _ -> :ok end, opts)

      started_days_ago = System.system_time(:second) - 3 * 86_400
      now = System.system_time(:second) + 360
      refute Updater.rollback_due?(c.config, started_days_ago, now, "0.1.0")
      assert Updater.rollback_due?(c.config, started_days_ago, now, "0.2.0")
    end
  end
end
