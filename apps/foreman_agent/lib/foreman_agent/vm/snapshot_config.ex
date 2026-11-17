defmodule ForemanAgent.VM.SnapshotConfig do
  @moduledoc """
  Checks the config Cloud Hypervisor saved with a VM's snapshot
  (`snapshot/config.json`) before the VM is restored from it.

  A restore takes everything from that file: the disks and kernel it
  opens, the sockets it makes, whether it turns Landlock on and with which
  rules, and Cloud Hypervisor adds every file the config names to those
  rules. It opens the disks and the console before Landlock confines it.
  The file is in the VM's own directory, which the VM can write, so a VMM
  that got out of its guest could turn Landlock off for its next resume,
  or name another environment's disk.

  So the config has to be the one `vmctl start` gives a VM: its own disks,
  and the agent disk and kernel it booted with, all raw images (a qcow2
  header names a backing file, which would be opened too), the agent disk
  read-only; the tap the helper gave it; its own serial log and vsock
  socket; Landlock on, with start's rules; and no other device or file. Anything else in
  it (sizes, queues, PCI ids, the balloon) opens nothing.
  """

  @type want :: %{dir: Path.t(), guest: Path.t(), agent_disk: Path.t(), tap: String.t()}

  # The config's settings that start gives a VM. Any other one must be
  # empty: those are devices, and devices open files and sockets.
  @settings ~w(cpus memory payload rate_limit_groups disks net rng balloon serial console
               debug_console vsock pvpanic numa watchdog rtc pci_segments platform
               landlock_enable landlock_rules)

  @doc "Checks the config at `path`, which must be a plain file."
  @spec check_file(Path.t(), want()) :: :ok | {:error, String.t()}
  def check_file(path, want) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, json} <- File.read(path) do
      check(json, want)
    else
      _ -> {:error, "the snapshot's config isn't a plain file"}
    end
  end

  @doc """
  Checks a saved config against what start gave the VM: `dir` is the VM's
  directory, `guest` the guest image's, `agent_disk` the agent disk it
  booted with and `tap` the tap the helper gave it.
  """
  @spec check(String.t(), want()) :: :ok | {:error, String.t()}
  def check(json, want) do
    case JSON.decode(json) do
      {:ok, %{} = config} ->
        case problem(config, want) do
          nil -> :ok
          why -> {:error, "the snapshot's config " <> why}
        end

      _ ->
        {:error, "the snapshot's config isn't one Cloud Hypervisor wrote"}
    end
  end

  defp problem(config, want) do
    tap = own_tap(config["net"], want.tap)

    checks = [
      {fn -> config["landlock_enable"] == true end, "turns Landlock off"},
      {fn -> tap != nil end, "has a network other than the VM's own tap"},
      {fn -> rules?(config["landlock_rules"], want, tap) end,
       "has Landlock rules start doesn't give"},
      {fn -> payload?(config["payload"], want) end,
       "boots a kernel other than the guest image's"},
      {fn -> disks?(config["disks"], want) end, "has disks other than the VM's own"},
      {fn -> get(config, ["rng", "src"]) == "/dev/urandom" end,
       "takes randomness from somewhere other than /dev/urandom"},
      {fn -> consoles?(config, want) end,
       "writes a console somewhere other than the VM's serial log"},
      {fn -> get(config, ["vsock", "socket"]) == Path.join(want.dir, "vsock.sock") end,
       "has a vsock socket other than the VM's own"},
      {fn -> blank?(get(config, ["memory", "zones"])) end, "maps memory from files"}
    ]

    Enum.find_value(checks, fn {ok?, why} -> if ok?.(), do: nil, else: why end) ||
      Enum.find_value(Enum.sort(Map.keys(config)), fn key ->
        if key not in @settings and not blank?(config[key]),
          do: "has #{key}, which start doesn't give a VM"
      end)
  end

  # The VM's own tap, opened by name: not over vhost-user, and not from
  # file descriptors.
  defp own_tap([%{"tap" => tap} = net], tap) do
    if Enum.all?(~w(vhost_user vhost_socket fds), &blank?(net[&1])), do: tap
  end

  defp own_tap(_net, _tap), do: nil

  # vmctl's rules, exactly.
  defp rules?(rules, want, tap) when is_list(rules) and is_binary(tap) do
    start =
      for {path, access} <- [
            {want.dir, "rw"},
            {want.guest, "r"},
            {want.agent_disk, "r"},
            {"/dev/net/tun", "rw"},
            {"/sys/devices/virtual/net/" <> tap, "r"}
          ],
          do: %{"path" => path, "access" => access}

    Enum.sort(rules) == Enum.sort(start)
  end

  defp rules?(_rules, _want, _tap), do: false

  # The guest image's kernel and a command line: no initramfs, firmware
  # or anything else to load.
  defp payload?(%{} = payload, want) do
    payload["kernel"] == Path.join(want.guest, "vmlinuz") and
      Enum.all?(Map.drop(payload, ~w(kernel cmdline)), fn {_key, value} -> blank?(value) end)
  end

  defp payload?(_payload, _want), do: false

  # The VM's root and data disks and the agent disk, once each, as raw
  # images in files.
  defp disks?(disks, want) when is_list(disks) do
    own = [Path.join(want.dir, "root.raw"), Path.join(want.dir, "data.raw"), want.agent_disk]

    Enum.sort(Enum.map(disks, &get(&1, ["path"]))) == Enum.sort(own) and
      Enum.all?(disks, fn disk ->
        disk["image_type"] == "Raw" and blank?(disk["backing_files"]) and
          blank?(disk["vhost_user"]) and blank?(disk["vhost_socket"]) and
          (disk["path"] != want.agent_disk or disk["readonly"] == true)
      end)
  end

  defp disks?(_disks, _want), do: false

  # The serial console to the VM's serial.log; the virtio console and the
  # debug console off.
  defp consoles?(config, want) do
    serial = config["serial"]
    debug = config["debug_console"]

    get(serial, ["mode"]) == "File" and
      get(serial, ["file"]) == Path.join(want.dir, "serial.log") and
      blank?(get(serial, ["socket"])) and
      off?(config["console"]) and
      (debug == nil or off?(debug))
  end

  defp off?(%{"mode" => "Off"} = console),
    do: blank?(console["file"]) and blank?(console["socket"])

  defp off?(_console), do: false

  defp get(value, []), do: value
  defp get(%{} = map, [key | rest]), do: get(Map.get(map, key), rest)
  defp get(_value, _keys), do: nil

  defp blank?(value), do: value in [nil, false, []]
end
