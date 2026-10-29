defmodule Foreman.Boxes.FlatcarTest do
  @moduledoc """
  The first-boot config (Ignition) for a box that runs Flatcar Container
  Linux: Compose and Tailscale as system extensions, the tailnet, and a
  unit that installs the agent with the control plane's install script.
  """
  use ExUnit.Case, async: true

  alias Foreman.Boxes.Flatcar

  @opts %{
    url: "https://foreman.tail1234.ts.net",
    join_token: "fj_secret",
    name: "studio",
    arch: "arm64",
    tailscale_auth_key: "tskey-auth-abc",
    ssh_keys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore core@mac"]
  }

  defp ignition(overrides \\ %{}) do
    assert {:ok, config} = Flatcar.ignition(Map.merge(@opts, overrides))
    # What goes on the wire.
    config |> JSON.encode!() |> JSON.decode!()
  end

  defp file(config, path) do
    Enum.find(config["storage"]["files"], &(&1["path"] == path)) ||
      flunk("no #{path} in #{inspect(Enum.map(config["storage"]["files"], & &1["path"]))}")
  end

  # Files are inline data: URLs, base64.
  defp contents(config, path) do
    "data:;base64," <> data = file(config, path)["contents"]["source"]
    Base.decode64!(data)
  end

  defp unit(config, name) do
    Enum.find(config["systemd"]["units"], &(&1["name"] == name)) || flunk("no unit #{name}")
  end

  defp link(config, path), do: Enum.find(config["storage"]["links"], &(&1["path"] == path))

  test "is Ignition 3.4" do
    assert ignition()["ignition"]["version"] == "3.4.0"
  end

  test "names the box" do
    assert contents(ignition(), "/etc/hostname") == "studio\n"
  end

  # Foreman shows an applied update as a reboot the box needs, and an
  # admin reboots it. Flatcar's own reboot manager would pick its own time.
  test "turns Flatcar's reboot manager off" do
    assert contents(ignition(), "/etc/flatcar/update.conf") =~ ~r/^REBOOT_STRATEGY=off$/m
  end

  for {arch, suffix} <- [{"amd64", "x86-64"}, {"arm64", "arm64"}] do
    test "adds Compose and Tailscale for #{arch}, checked against pinned digests" do
      config = ignition(%{arch: unquote(arch)})

      for name <- ["docker-compose", "tailscale"] do
        link = link(config, "/etc/extensions/#{name}.raw")
        assert link, "no extension link for #{name}"

        assert link["target"] =~
                 ~r{^/opt/extensions/#{name}/#{name}-v?[0-9.]+-#{unquote(suffix)}\.raw$}

        file = file(config, link["target"])

        assert file["contents"]["source"] ==
                 "https://extensions.flatcar.org/extensions/" <> Path.basename(link["target"])

        assert file["contents"]["verification"]["hash"] =~ ~r/^sha256-[0-9a-f]{64}$/

        assert contents(config, "/etc/sysupdate.#{name}.d/#{name}.conf") =~
                 "MatchPattern=#{name}-@v-%a.raw"
      end
    end
  end

  test "different architectures get different extension images" do
    hashes = fn arch ->
      config = ignition(%{arch: arch})

      for name <- ["docker-compose", "tailscale"],
          do:
            file(config, link(config, "/etc/extensions/#{name}.raw")["target"])["contents"][
              "verification"
            ]["hash"]
    end

    assert MapSet.disjoint?(MapSet.new(hashes.("amd64")), MapSet.new(hashes.("arm64")))
  end

  test "updates the extensions, and says when one waits for a reboot" do
    config = ignition()
    assert unit(config, "systemd-sysupdate.timer")["enabled"]
    [dropin] = unit(config, "systemd-sysupdate.service")["dropins"]
    assert dropin["contents"] =~ "/opt/foreman-box/update-sysexts"

    script = contents(config, "/opt/foreman-box/update-sysexts")
    assert script =~ "systemd-sysupdate"
    assert script =~ "/run/reboot-required"
    assert file(config, "/opt/foreman-box/update-sysexts")["mode"] == 0o755
    # Only the extensions are updated this way; the OS updates itself.
    assert contents(config, "/etc/sysupdate.d/noop.conf") =~ "invalid@v.raw"
  end

  test "runs tailscaled with the defaults the extension's unit needs" do
    config = ignition()
    assert contents(config, "/etc/default/tailscaled") =~ ~r/^PORT=/m
    assert contents(config, "/etc/default/tailscaled") =~ ~r/^FLAGS=/m
    assert unit(config, "tailscaled.service")["enabled"]
  end

  test "keeps the join token and the Tailscale key root's alone" do
    config = ignition()
    env = contents(config, "/etc/foreman-box/provision.env")
    assert env =~ ~s(FOREMAN_URL="https://foreman.tail1234.ts.net")
    assert env =~ ~s(FOREMAN_JOIN_TOKEN="fj_secret")
    assert env =~ ~s(FOREMAN_BOX_NAME="studio")
    assert file(config, "/etc/foreman-box/provision.env")["mode"] == 0o600

    assert contents(config, "/etc/foreman-box/tailscale-authkey") == "tskey-auth-abc"
    assert file(config, "/etc/foreman-box/tailscale-authkey")["mode"] == 0o600
  end

  test "without a Tailscale key the box relies on reaching the control plane as it is" do
    config = ignition(%{tailscale_auth_key: nil})

    refute Enum.any?(
             config["storage"]["files"],
             &(&1["path"] == "/etc/foreman-box/tailscale-authkey")
           )
  end

  test "installs the agent once, on the network and after tailscaled" do
    config = ignition()
    provision = unit(config, "foreman-provision.service")
    assert provision["enabled"]
    assert provision["contents"] =~ "ConditionPathExists=/etc/foreman-box/provision.env"
    assert provision["contents"] =~ "After=network-online.target tailscaled.service"
    assert provision["contents"] =~ "ExecStart=/opt/foreman-box/provision"
    assert provision["contents"] =~ "Restart=on-failure"

    script = contents(config, "/opt/foreman-box/provision")
    assert script =~ "tailscale up"
    assert script =~ "/agent/install.sh"
    assert file(config, "/opt/foreman-box/provision")["mode"] == 0o755
  end

  # A Mac's VM doesn't see time pass while the Mac sleeps; its clock
  # falls behind, and the control plane refuses an agent whose signed
  # clock is a minute off.
  test "puts the clock right after a Mac sleeps, on Apple's hypervisor only" do
    config = ignition()
    timer = unit(config, "foreman-clock.timer")
    assert timer["enabled"]
    assert unit(config, "foreman-clock.service")["contents"] =~ "ConditionVirtualization=apple"
    assert contents(config, "/opt/foreman-box/clock-sync") =~ "/sys/class/rtc/rtc0/since_epoch"
  end

  # The address a DHCP server (a Mac's vmnet, a router's reservations)
  # hands out then follows the MAC address, the same in every boot.
  test "asks DHCP for an address by MAC address" do
    assert contents(ignition(), "/etc/systemd/network/zz-default.network.d/foreman-dhcp.conf") =~
             "ClientIdentifier=mac"
  end

  test "lets the given SSH keys in as core" do
    assert [%{"name" => "core", "sshAuthorizedKeys" => [key]}] = ignition()["passwd"]["users"]
    assert key =~ "core@mac"
    refute Map.has_key?(ignition(%{ssh_keys: []}), "passwd")
  end

  test "refuses an architecture Flatcar doesn't ship" do
    assert {:error, :bad_arch} = Flatcar.ignition(%{@opts | arch: "riscv64"})
  end

  test "refuses a key that isn't an SSH public key" do
    assert {:error, :bad_ssh_key} =
             Flatcar.ignition(%{@opts | ssh_keys: ["not a key\nwith a newline"]})
  end

  test "quotes values in the env file so nothing in them runs" do
    config = ignition(%{name: "studio", url: "https://foreman.example/$(reboot)"})

    assert contents(config, "/etc/foreman-box/provision.env") =~
             ~s|FOREMAN_URL="https://foreman.example/\\$(reboot)"|
  end
end
