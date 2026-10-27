defmodule ForemanAgent.Reboot do
  @moduledoc """
  Whether the box needs a reboot, for `box.reboot`.

  Debian's convention: a package whose update needs a reboot writes
  `/run/reboot-required` and adds itself to `/run/reboot-required.pkgs`,
  and a reboot clears both. On Ubuntu update-notifier's hooks do it for
  the kernel, libc and the like; on Debian it's up to each package (a
  kernel through linux-base, dbus-broker), so coverage varies. The flag is
  a request, not a check: it says something asked for a reboot.

  Livepatch (or kpatch) loads its patches as kernel livepatch modules,
  listed under `/sys/kernel/livepatch` with an `enabled` flag, which the
  agent can read without root. That's shown beside the reboot, not used
  to excuse it: it says a patch is in, not which fixes.
  """

  alias ForemanAgent.Config

  # The list is only for people to read on the box's page.
  @max_packages 50

  @spec report(Config.t()) :: %{required: boolean(), packages: [String.t()], livepatch: boolean()}
  def report(%Config{} = config) do
    %{
      required: File.exists?(config.reboot_required),
      packages: packages(config.reboot_required <> ".pkgs"),
      livepatch: livepatch?(config.livepatch_dir)
    }
  end

  defp packages(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or not String.valid?(&1) or byte_size(&1) > 255))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.take(@max_packages)

      {:error, _} ->
        []
    end
  end

  defp livepatch?(dir) do
    case File.ls(dir) do
      {:ok, patches} ->
        Enum.any?(patches, fn patch ->
          match?({:ok, "1" <> _}, File.read(Path.join([dir, patch, "enabled"])))
        end)

      {:error, _} ->
        false
    end
  end
end
