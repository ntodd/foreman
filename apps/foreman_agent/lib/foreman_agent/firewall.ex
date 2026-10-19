defmodule ForemanAgent.Firewall do
  @moduledoc """
  Whether the box's firewall is loaded, for the join payload.

  The firewall (`priv/firewall/foreman.nft`) keeps environments, and
  Docker's default bridge where image builds run, off the tailnet as the
  box. The install script loads it as root with `foreman-firewall.service`;
  the agent can't read nftables itself, so the unit leaves a marker in
  `/run/foreman-firewall` once the rules are in (systemd removes it when
  the unit stops, and the check timer while the rules won't load). The
  marker names the rules it was installed from, so a box whose agent
  updated itself past them shows as outdated until the install script
  runs again. The default bridge setting comes from the install script's
  copy in `/etc/foreman-agent`, which outlives the marker: the command to
  repair a box needs it.
  """

  alias ForemanAgent.Config

  @spec report(Config.t()) :: map()
  def report(%Config{} = config) do
    marker = read(config.firewall_marker)
    info = read(config.firewall_info) || marker || %{}

    state =
      case marker do
        nil -> "missing"
        %{"source_sha256" => sha} -> if sha == bundled_sha(config), do: "active", else: "outdated"
        _ -> "outdated"
      end

    case info["default_bridge"] do
      bridge when bridge in ["filtered", "reaches_tailnet"] ->
        %{firewall: state, firewall_default_bridge: bridge}

      _ ->
        %{firewall: state}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, _} -> nil
    end
  end

  defp parse(marker) do
    for line <- String.split(marker, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {String.trim(key), String.trim(value)}
  end

  defp bundled_sha(config) do
    case File.read(config.firewall_rules) do
      {:ok, rules} -> :crypto.hash(:sha256, rules) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end
end
