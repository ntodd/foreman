defmodule Foreman.Boxes.Flatcar do
  @moduledoc """
  The first-boot config (Ignition) for a box that runs Flatcar Container
  Linux, on bare metal or as a VM (the Mac and Linux launchers,
  `priv/agent/mac.sh` and `priv/agent/vm.sh`, boot it with this).

  Flatcar has Docker, git and nftables already. The config adds:

  - Compose and Tailscale as system extensions from Flatcar's sysext
    bakery, checked against the digests pinned here, and kept up to date
    by systemd-sysupdate. A new one takes effect on the next boot and is
    flagged as a reboot the box needs.
  - tailscaled, and the box's own Tailscale key when the control plane
    minted one.
  - `foreman-provision.service`, which joins the tailnet, waits for the
    control plane and runs its install script with the join token, then
    deletes the token and the key.
  - Flatcar's reboot manager turned off: Foreman shows an applied OS
    update as a reboot the box needs, and an admin reboots it.
  - On Apple's hypervisor, a timer that sets the clock from the RTC after
    the Mac sleeps.
  - DHCP by MAC address, so a box keeps its address from boot to boot (a
    Mac's launcher finds its VM that way).
  """

  @scripts Path.expand("../../../priv/flatcar", __DIR__)
  for script <- ~w(provision.sh update-sysexts.sh clock-sync.sh),
      do: @external_resource(Path.join(@scripts, script))

  @provision File.read!(Path.join(@scripts, "provision.sh"))
  @update_sysexts File.read!(Path.join(@scripts, "update-sysexts.sh"))
  @clock_sync File.read!(Path.join(@scripts, "clock-sync.sh"))

  @bakery "https://extensions.flatcar.org/extensions"

  # From the bakery's SHA256SUMS (the metadata release of each
  # extension). The bakery names amd64 x86-64.
  @sysexts [
    {"docker-compose", "5.6.1",
     %{
       "amd64" => "b3d4ac98757e541ac3e84b8e2dfa2e2505e1f71619f40b0f53770517397effeb",
       "arm64" => "a38de0665aa8abf9eabda5717a78fc94df60ec5fab5736b7ae4c9546f7063515"
     }},
    {"tailscale", "v1.104.4",
     %{
       "amd64" => "e4e4a13af92b61711ea3a9a4413e7769502024b33f60860c9de15a270021b221",
       "arm64" => "e6ef409eb52e4fc10fc08b5011274b03f54181b1c7bdef3c3a5f5c48e6bd7f37"
     }}
  ]

  @bakery_arch %{"amd64" => "x86-64", "arm64" => "arm64"}

  @ssh_key ~r/\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+\/=]+( [^\r\n]*)?\z/

  @type opts :: %{
          url: String.t(),
          join_token: String.t(),
          name: String.t(),
          arch: String.t(),
          tailscale_auth_key: String.t() | nil,
          ssh_keys: [String.t()]
        }

  @doc "The architectures Flatcar ships, as Foreman names them."
  def arches, do: Map.keys(@bakery_arch)

  @doc """
  The Ignition config (a map, JSON-ready) for a box. `:tailscale_auth_key`
  may be nil (the box then has to reach the control plane without
  joining the tailnet itself); `:ssh_keys` go to the `core` user.
  """
  @spec ignition(opts()) :: {:ok, map()} | {:error, :bad_arch | :bad_ssh_key}
  def ignition(opts) do
    ssh_keys = Map.get(opts, :ssh_keys, []) |> Enum.map(&String.trim/1)

    cond do
      not Map.has_key?(@bakery_arch, opts.arch) -> {:error, :bad_arch}
      not Enum.all?(ssh_keys, &Regex.match?(@ssh_key, &1)) -> {:error, :bad_ssh_key}
      true -> {:ok, build(opts, ssh_keys)}
    end
  end

  defp build(opts, ssh_keys) do
    {ext_files, ext_links} = extensions(opts.arch)

    config = %{
      "ignition" => %{"version" => "3.4.0"},
      "storage" => %{
        "files" =>
          [
            text("/etc/hostname", opts.name <> "\n", 0o644),
            text("/etc/flatcar/update.conf", "REBOOT_STRATEGY=off\n", 0o644),
            text("/etc/default/tailscaled", ~s(PORT="41641"\nFLAGS=""\n), 0o644),
            text(
              "/etc/systemd/network/zz-default.network.d/foreman-dhcp.conf",
              "[DHCPv4]\nClientIdentifier=mac\n",
              0o644
            ),
            text("/etc/sysupdate.d/noop.conf", noop_sysupdate(), 0o644),
            text("/opt/foreman-box/update-sysexts", @update_sysexts, 0o755),
            text("/opt/foreman-box/provision", @provision, 0o755),
            text("/opt/foreman-box/clock-sync", @clock_sync, 0o755),
            text("/etc/foreman-box/provision.env", provision_env(opts), 0o600)
          ] ++
            tailscale_key(opts[:tailscale_auth_key]) ++ ext_files,
        "links" => ext_links
      },
      "systemd" => %{"units" => units()}
    }

    case ssh_keys do
      [] ->
        config

      keys ->
        Map.put(config, "passwd", %{"users" => [%{"name" => "core", "sshAuthorizedKeys" => keys}]})
    end
  end

  defp tailscale_key(key) when is_binary(key) and key != "",
    do: [text("/etc/foreman-box/tailscale-authkey", key, 0o600)]

  defp tailscale_key(_), do: []

  defp extensions(arch) do
    for {name, version, digests} <- @sysexts, reduce: {[], []} do
      {files, links} ->
        image = "#{name}-#{version}-#{@bakery_arch[arch]}.raw"
        path = "/opt/extensions/#{name}/#{image}"

        file = %{
          "path" => path,
          "mode" => 0o644,
          "contents" => %{
            "source" => "#{@bakery}/#{image}",
            "verification" => %{"hash" => "sha256-" <> digests[arch]}
          }
        }

        link = %{"path" => "/etc/extensions/#{name}.raw", "target" => path, "hard" => false}

        {files ++ [file, text("/etc/sysupdate.#{name}.d/#{name}.conf", sysupdate(name), 0o644)],
         links ++ [link]}
    end
  end

  defp sysupdate(name) do
    """
    [Transfer]
    Verify=false

    [Source]
    Type=url-file
    Path=#{@bakery}/#{name}/
    MatchPattern=#{name}-@v-%a.raw

    [Target]
    InstancesMax=3
    Type=regular-file
    Path=/opt/extensions/#{name}
    CurrentSymlink=/etc/extensions/#{name}.raw
    """
  end

  # systemd-sysupdate.service updates whatever /etc/sysupdate.d lists; the
  # extensions are updated by name (update-sysexts), so this lists nothing.
  defp noop_sysupdate do
    """
    [Source]
    Type=regular-file
    Path=/
    MatchPattern=invalid@v.raw
    [Target]
    Type=regular-file
    Path=/
    """
  end

  defp provision_env(opts) do
    """
    FOREMAN_URL=#{quote_env(opts.url)}
    FOREMAN_JOIN_TOKEN=#{quote_env(opts.join_token)}
    FOREMAN_BOX_NAME=#{quote_env(opts.name)}
    """
  end

  # Sourced by a shell: inside double quotes, only these are special.
  defp quote_env(value),
    do: ~s(") <> String.replace(value, ["\\", "\"", "$", "`"], &("\\" <> &1)) <> ~s(")

  defp units do
    [
      %{"name" => "tailscaled.service", "enabled" => true},
      %{"name" => "systemd-sysupdate.timer", "enabled" => true},
      %{
        "name" => "systemd-sysupdate.service",
        "dropins" => [
          %{
            "name" => "foreman-sysexts.conf",
            "contents" => "[Service]\nExecStartPre=/opt/foreman-box/update-sysexts\n"
          }
        ]
      },
      %{
        "name" => "foreman-provision.service",
        "enabled" => true,
        "contents" => """
        [Unit]
        Description=Install the Foreman agent and enroll this box
        ConditionPathExists=/etc/foreman-box/provision.env
        Wants=network-online.target tailscaled.service
        After=network-online.target tailscaled.service

        [Service]
        Type=oneshot
        ExecStart=/opt/foreman-box/provision
        Restart=on-failure
        RestartSec=30
        # The script writes its progress to the consoles itself.
        StandardOutput=journal
        StandardError=journal

        [Install]
        WantedBy=multi-user.target
        """
      },
      %{
        "name" => "foreman-clock.service",
        "contents" => """
        [Unit]
        Description=Set the clock from the RTC after the Mac sleeps
        ConditionVirtualization=apple

        [Service]
        Type=oneshot
        ExecStart=/opt/foreman-box/clock-sync
        """
      },
      %{
        "name" => "foreman-clock.timer",
        "enabled" => true,
        "contents" => """
        [Unit]
        Description=Check the clock against the RTC
        ConditionVirtualization=apple

        [Timer]
        OnBootSec=10s
        OnUnitActiveSec=10s
        AccuracySec=1s

        [Install]
        WantedBy=timers.target
        """
      }
    ]
  end

  defp text(path, content, mode) do
    %{
      "path" => path,
      "mode" => mode,
      "overwrite" => true,
      "contents" => %{"source" => "data:;base64," <> Base.encode64(content)}
    }
  end
end
