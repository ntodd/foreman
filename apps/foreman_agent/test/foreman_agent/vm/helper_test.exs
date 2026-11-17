defmodule ForemanAgent.VM.HelperTest do
  # The agent's side of foreman-vmctl, against a stand-in on a unix socket
  # that answers each request line from a table.
  use ExUnit.Case, async: true

  alias ForemanAgent.Config
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

  defp helper(ctx, answers) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, ctx.socket}}, packet: :line, active: false])

    pid = spawn_link(fn -> serve(listen, answers) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    %Config{vmctl_socket: ctx.socket}
  end

  defp serve(listen, answers) do
    {:ok, client} = :gen_tcp.accept(listen)
    {:ok, line} = :gen_tcp.recv(client, 0)
    request = line |> String.trim_trailing() |> String.split() |> hd()
    :ok = :gen_tcp.send(client, Map.get(answers, request, "error unknown request") <> "\n")
    :gen_tcp.close(client)
    serve(listen, answers)
  end

  describe "ready/1" do
    test "a current helper on a kernel with Landlock is ready", ctx do
      config = helper(ctx, %{"version" => "ok 2", "landlock" => "ok"})
      assert Helper.ready(config) == :ok
    end

    test "a helper from before Landlock was required is too old", ctx do
      config = helper(ctx, %{"version" => "ok 1"})
      assert Helper.ready(config) == {:error, @too_old}
    end

    test "a box whose kernel has no Landlock says so, in the helper's words", ctx do
      config = helper(ctx, %{"version" => "ok 2", "landlock" => "error " <> @no_landlock})
      assert Helper.ready(config) == {:error, @no_landlock}
    end

    test "a box with no helper isn't ready", ctx do
      assert Helper.ready(%Config{vmctl_socket: ctx.socket}) == {:error, @too_old}
    end
  end
end
