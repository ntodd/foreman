defmodule ForemanAgent.VM.HelperTest do
  # The agent's side of foreman-vmctl, against a stand-in on a unix socket
  # that answers each request line from a table (Test.FakeVmctl).
  use ExUnit.Case, async: true

  alias ForemanAgent.Config
  alias ForemanAgent.Test.FakeVmctl
  alias ForemanAgent.VM.Helper

  @too_old "the VM helper is missing or too old; re-run the install script"
  @no_landlock "this box's kernel has no Landlock: environment VMs need Linux 6.2 or later with landlock in its LSM list"

  setup do
    # Unix socket paths are short on macOS; System.tmp_dir/0 is long there.
    dir = Path.join("/tmp", "fmh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{socket: Path.join(dir, "vmctl.sock")}
  end

  defp helper(ctx, answers), do: FakeVmctl.start(ctx.socket, answers)

  describe "ready/1" do
    test "a current helper on a kernel with Landlock is ready", ctx do
      config = helper(ctx, %{"version" => "ok 4", "landlock" => "ok"})
      assert Helper.ready(config) == :ok
    end

    test "a helper that immediately recycles addresses cannot release a lease", ctx do
      config = helper(ctx, %{"version" => "ok 3"})
      assert Helper.ready(config) == {:error, @too_old}
      assert Helper.release(config, "env") == {:error, @too_old}
    end

    test "a helper with shared-ownership VM taps is too old", ctx do
      config = helper(ctx, %{"version" => "ok 2"})
      assert Helper.ready(config) == {:error, @too_old}
    end

    test "a box whose kernel has no Landlock says so, in the helper's words", ctx do
      config = helper(ctx, %{"version" => "ok 4", "landlock" => "error " <> @no_landlock})
      assert Helper.ready(config) == {:error, @no_landlock}
    end

    test "a box with no helper isn't ready", ctx do
      assert Helper.ready(%Config{vmctl_socket: ctx.socket}) == {:error, @too_old}
    end
  end

  describe "tap/2" do
    test "names the tap the helper gave the VM", ctx do
      config = helper(ctx, %{"tap" => "ok fm-vm3"})
      assert Helper.tap(config, "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f") == {:ok, "fm-vm3"}
      assert_received {:vmctl, "tap 6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"}
    end

    test "says so when the VM has none", ctx do
      config = helper(ctx, %{"tap" => "error the environment has no address"})

      assert Helper.tap(config, "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f") ==
               {:error, "the environment has no address"}
    end
  end
end
