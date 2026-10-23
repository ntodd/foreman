defmodule Foreman.UpdatesTest do
  # The latest release is cached globally, and the update directory is
  # app config.
  use Foreman.DataCase, async: false

  import Foreman.Fixtures

  alias Foreman.Updates

  setup do
    Application.put_env(:foreman, :updates_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    dir = Path.join(System.tmp_dir!(), "foreman-update-#{unique()}")
    File.mkdir_p!(Path.join(dir, "request"))
    File.mkdir_p!(Path.join(dir, "status"))
    Application.put_env(:foreman, :update_dir, dir)
    Updates.reset()

    on_exit(fn ->
      Application.delete_env(:foreman, :updates_req_options)
      Application.delete_env(:foreman, :update_dir)
      Updates.reset()
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp release(tag, opts \\ []) do
    %{
      "tag_name" => tag,
      "html_url" => "https://github.com/ntodd/foreman/releases/tag/#{tag}",
      "published_at" => Keyword.get(opts, :published_at, "2026-10-22T14:08:23Z"),
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false)
    }
  end

  defp github_releases(releases) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/ntodd/foreman/releases"
      Req.Test.json(conn, releases)
    end)
  end

  defp installed(dir, state \\ nil) do
    File.write!(Path.join(dir, "status/updater"), "1\n")
    if state, do: File.write!(Path.join(dir, "status/state.json"), JSON.encode!(state))
  end

  defp admin, do: Foreman.Scope.for_user(user_fixture(role: "admin"))

  describe "check/0" do
    test "finds the highest published vX.Y.Z release" do
      github_releases([
        # A patch on an older line, published last.
        release("v0.3.9", published_at: "2026-10-23T09:00:00Z"),
        release("v0.4.10"),
        release("v0.4.9"),
        release("v0.5.0", draft: true),
        release("v0.5.0-rc.1", prerelease: true),
        release("nightly")
      ])

      assert {:ok, %{version: "0.4.10", url: url}} = Updates.check()
      assert url == "https://github.com/ntodd/foreman/releases/tag/v0.4.10"
      assert %{version: "0.4.10", checked_at: %DateTime{}} = Updates.latest()
    end

    test "an update is available only when the release is newer than this one" do
      github_releases([release("v0.4.7")])
      {:ok, _} = Updates.check()
      assert %{version: "0.4.7"} = Updates.available()

      github_releases([release("v#{Foreman.Config.version()}")])
      {:ok, _} = Updates.check()
      assert Updates.available() == nil
    end

    test "a failed check keeps what the last one found" do
      github_releases([release("v0.4.7")])
      {:ok, _} = Updates.check()

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 502, "bad gateway"))
      assert {:error, _} = Updates.check()
      assert %{version: "0.4.7", error: error} = Updates.latest()
      assert error =~ "502"
    end

    test "the job does nothing when checking is turned off" do
      Application.put_env(:foreman, :update_check, false)
      on_exit(fn -> Application.delete_env(:foreman, :update_check) end)

      Req.Test.stub(__MODULE__, fn _conn -> flunk("checked GitHub") end)
      assert :ok = Foreman.Jobs.CheckForUpdates.perform(%Oban.Job{args: %{}})
      assert Updates.latest() == nil
    end

    test "the job checks every five minutes and doesn't retry" do
      crontab =
        Enum.find_value(Application.fetch_env!(:foreman, Oban)[:plugins], fn
          {Oban.Plugins.Cron, opts} -> opts[:crontab]
          _ -> nil
        end)

      assert {"*/5 * * * *", Foreman.Jobs.CheckForUpdates} in crontab
      assert Foreman.Jobs.CheckForUpdates.__opts__()[:max_attempts] == 1
    end
  end

  describe "updater/0" do
    test "not installed without the host's marker", %{dir: dir} do
      assert %{installed: false} = Updates.updater()
      File.rm_rf!(dir)
      assert %{installed: false} = Updates.updater()
    end

    test "reads the host's last run", %{dir: dir} do
      installed(dir, %{
        "state" => "rolled_back",
        "from" => "0.4.6",
        "to" => "0.4.7",
        "message" => "0.4.7 never became healthy",
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      assert %{
               installed: true,
               state: "rolled_back",
               from: "0.4.6",
               to: "0.4.7",
               message: "0.4.7 never became healthy",
               at: %DateTime{}
             } = Updates.updater()
    end

    test "an unreadable state file is no state", %{dir: dir} do
      installed(dir)
      File.write!(Path.join(dir, "status/state.json"), "{not json")
      assert %{installed: true, state: nil} = Updates.updater()
    end

    test "a run that stopped reporting long ago is stale", %{dir: dir} do
      installed(dir, %{
        "state" => "running",
        "to" => "0.4.7",
        "at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3600))
      })

      assert %{state: "stale"} = Updates.updater()
    end

    test "a request the host hasn't picked up yet is pending", %{dir: dir} do
      installed(dir)
      File.write!(Path.join(dir, "request/version"), "0.4.7\n")
      assert %{state: "pending", to: "0.4.7"} = Updates.updater()
    end
  end

  describe "request/2" do
    setup %{dir: dir} do
      installed(dir)
      github_releases([release("v0.4.7")])
      {:ok, _} = Updates.check()
      :ok
    end

    test "writes the version for the host's updater and audits it", %{dir: dir} do
      scope = admin()
      assert :ok = Updates.request(scope, "0.4.7")

      assert File.read!(Path.join(dir, "request/version")) == "0.4.7\n"
      assert File.ls!(Path.join(dir, "request")) == ["version"]

      assert [%{action: "foreman.update", metadata: %{"to" => "0.4.7", "from" => from}}] =
               Foreman.Audit.recent()

      assert from == Foreman.Config.version()
    end

    test "admins only", %{dir: dir} do
      member = Foreman.Scope.for_user(user_fixture())
      assert {:error, :forbidden} = Updates.request(member, "0.4.7")
      refute File.exists?(Path.join(dir, "request/version"))
    end

    test "only the release the check found", %{dir: dir} do
      assert {:error, :not_available} = Updates.request(admin(), "0.4.8")
      assert {:error, :not_available} = Updates.request(admin(), "../../etc/passwd")
      refute File.exists?(Path.join(dir, "request/version"))
    end

    test "needs the host's updater", %{dir: dir} do
      File.rm!(Path.join(dir, "status/updater"))
      assert {:error, :no_updater} = Updates.request(admin(), "0.4.7")
    end

    test "one at a time", %{dir: dir} do
      assert :ok = Updates.request(admin(), "0.4.7")
      assert {:error, :in_progress} = Updates.request(admin(), "0.4.7")

      File.rm!(Path.join(dir, "request/version"))

      installed(dir, %{
        "state" => "running",
        "to" => "0.4.7",
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      assert {:error, :in_progress} = Updates.request(admin(), "0.4.7")
    end
  end
end
