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

  It also says whether the agent can reboot the box (`box.restart`, which
  needs the root unit the install script sets up) and which boot it's
  on: the kernel's boot id, which the command names.
  """

  alias ForemanAgent.Config

  # The list is only for people to read on the box's page.
  @max_packages 50

  @spec report(Config.t()) :: %{
          optional(:boot_id) => String.t(),
          required(:required) => boolean(),
          required(:packages) => [String.t()],
          required(:livepatch) => boolean(),
          required(:can_restart) => boolean()
        }
  def report(%Config{} = config) do
    report = %{
      required: File.exists?(config.reboot_required),
      packages: packages(config.reboot_required <> ".pkgs"),
      livepatch: livepatch?(config.livepatch_dir),
      can_restart: File.exists?(config.restart_unit)
    }

    case boot_id(config) do
      {:ok, id} -> Map.put(report, :boot_id, id)
      :error -> report
    end
  end

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "The kernel's id for this boot, which changes every boot."
  @spec boot_id(Config.t()) :: {:ok, String.t()} | :error
  def boot_id(%Config{boot_id: path}) do
    with {:ok, content} <- File.read(path),
         id = String.trim(content),
         true <- Regex.match?(@uuid, id) do
      {:ok, id}
    else
      _ -> :error
    end
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
