defmodule ForemanAgent.RebootTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, Reboot}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    %{
      config: %Config{
        reboot_required: Path.join(tmp, "run/reboot-required"),
        livepatch_dir: Path.join(tmp, "sys/kernel/livepatch")
      }
    }
  end

  defp flag(config, packages \\ nil) do
    File.mkdir_p!(Path.dirname(config.reboot_required))
    File.write!(config.reboot_required, "*** System restart required ***\n")
    if packages, do: File.write!(config.reboot_required <> ".pkgs", packages)
  end

  defp livepatch(config, name, enabled) do
    dir = Path.join(config.livepatch_dir, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "enabled"), "#{enabled}\n")
  end

  test "no flag, no reboot", %{config: config} do
    assert Reboot.report(config) == %{required: false, packages: [], livepatch: false}
  end

  # update-notifier's hooks write the flag, and the packages that asked
  # for the reboot beside it, one per line, repeated once per hook.
  test "the flag and the packages that asked for it", %{config: config} do
    flag(config, "linux-image-6.8.0-90-generic\nlibc6\nlinux-image-6.8.0-90-generic\n")

    assert Reboot.report(config) == %{
             required: true,
             packages: ["libc6", "linux-image-6.8.0-90-generic"],
             livepatch: false
           }
  end

  test "the flag without a package list", %{config: config} do
    flag(config)
    assert %{required: true, packages: []} = Reboot.report(config)
  end

  # Livepatch loads its patches as kernel livepatch modules, which show
  # in sysfs without root.
  test "a livepatch applied to the running kernel", %{config: config} do
    livepatch(config, "lkp_Ubuntu_6_8_0_90_generic_92", 1)
    assert %{livepatch: true} = Reboot.report(config)
  end

  test "a livepatch that's loaded but disabled doesn't count", %{config: config} do
    livepatch(config, "lkp_Ubuntu_6_8_0_90_generic_92", 0)
    assert %{livepatch: false} = Reboot.report(config)
  end

  test "keeps the package list short", %{config: config} do
    flag(config, Enum.map_join(1..80, "\n", &"pkg#{&1}"))
    assert length(Reboot.report(config).packages) == 50
  end
end
