defmodule ForemanAgent.Reboot do
  @moduledoc """
  Whether the box needs a reboot, for `box.reboot`.

  On Debian and Ubuntu, a package whose update needs one (a kernel, libc,
  systemd) runs update-notifier's hook, which writes `/run/reboot-required`
  and adds the package to `/run/reboot-required.pkgs`. A reboot clears
  both. Without update-notifier-common installed nothing writes them, and
  the box never reports a reboot.

  Livepatch (or kpatch) loads its patches as kernel livepatch modules,
  listed under `/sys/kernel/livepatch` with an `enabled` flag, which the
  agent can read without root. One that's enabled means the running
  kernel is patched, so a reboot that's only for a new kernel can wait.
  """

  alias ForemanAgent.Config

  # The list is for people to read on the box's page.
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
