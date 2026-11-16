defmodule ForemanAgent.RestartTest do
  @moduledoc """
  box.restart: the agent asks the root unit the install script set up
  (foreman-restart.path) to reboot the box, by writing a file it watches.
  The command names the boot the control plane saw, so one resent after
  the reboot (the agent had no time to answer) doesn't reboot it again.
  """
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, Restart}

  @moduletag :tmp_dir

  @boot_id "0b5a1f0e-7d1c-4c5e-9a43-5f1e2d3c4b5a"

  setup %{tmp_dir: tmp} do
    config = %Config{
      restart_unit: Path.join(tmp, "etc/systemd/system/foreman-restart.path"),
      restart_request: Path.join(tmp, "run/foreman/restart"),
      boot_id: Path.join(tmp, "proc/sys/kernel/random/boot_id")
    }

    for path <- [config.restart_unit, config.boot_id, config.restart_request],
        do: File.mkdir_p!(Path.dirname(path))

    File.write!(config.restart_unit, "[Path]\n")
    File.write!(config.boot_id, @boot_id <> "\n")
    %{config: config}
  end

  test "asks for the reboot on the boot it was sent for", %{config: config} do
    assert {:ok, %{"requested" => true}} = Restart.request(config, @boot_id)
    assert File.read!(config.restart_request) == @boot_id <> "\n"
  end

  test "a resend after the reboot is done already, and asks for nothing", %{config: config} do
    assert {:ok, %{"already" => true}} =
             Restart.request(config, "9f1e2d3c-4b5a-4c5e-9a43-0b5a1f0e7d1c")

    refute File.exists?(config.restart_request)
  end

  test "refuses on a box whose install predates the unit", %{config: config} do
    File.rm!(config.restart_unit)
    assert {:error, message} = Restart.request(config, @boot_id)
    assert message =~ "install"
    refute File.exists?(config.restart_request)
  end

  test "refuses when it can't tell which boot it's on", %{config: config} do
    File.rm!(config.boot_id)
    assert {:error, _} = Restart.request(config, @boot_id)
    refute File.exists?(config.restart_request)
  end
end
