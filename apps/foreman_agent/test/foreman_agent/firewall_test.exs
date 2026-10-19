defmodule ForemanAgent.FirewallTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.{Config, Firewall}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    rules = Path.join(tmp, "foreman.nft")
    File.write!(rules, "table inet foreman {}\n")

    config = %Config{
      firewall_rules: rules,
      firewall_marker: Path.join(tmp, "run/foreman-firewall/loaded"),
      firewall_info: Path.join(tmp, "etc/firewall.info")
    }

    %{
      config: config,
      sha: :crypto.hash(:sha256, File.read!(rules)) |> Base.encode16(case: :lower)
    }
  end

  defp mark(config, lines) do
    File.mkdir_p!(Path.dirname(config.firewall_marker))
    File.write!(config.firewall_marker, Enum.map_join(lines, &(&1 <> "\n")))
  end

  # foreman-firewall.service writes the marker once it has loaded the
  # rules, and systemd removes it when the unit stops.
  test "without the marker, the firewall isn't loaded", %{config: config} do
    assert Firewall.report(config) == %{firewall: "missing"}
  end

  test "loaded from the rules this agent ships with", %{config: config, sha: sha} do
    mark(config, ["source_sha256=#{sha}", "default_bridge=filtered"])
    assert Firewall.report(config) == %{firewall: "active", firewall_default_bridge: "filtered"}
  end

  # The install script copies the rules; a self-update doesn't.
  test "loaded from older rules than this agent's", %{config: config} do
    mark(config, ["source_sha256=#{String.duplicate("0", 64)}", "default_bridge=filtered"])
    assert %{firewall: "outdated"} = Firewall.report(config)
  end

  test "says when the default bridge is left out", %{config: config, sha: sha} do
    mark(config, ["source_sha256=#{sha}", "default_bridge=reaches_tailnet"])
    assert %{firewall_default_bridge: "reaches_tailnet"} = Firewall.report(config)
  end

  # The install script's copy, which outlives the marker: the box's
  # repair command needs the setting even while the rules aren't loaded.
  test "knows the default bridge setting with the firewall down", %{config: config, sha: sha} do
    File.mkdir_p!(Path.dirname(config.firewall_info))
    File.write!(config.firewall_info, "source_sha256=#{sha}\ndefault_bridge=reaches_tailnet\n")

    assert Firewall.report(config) == %{
             firewall: "missing",
             firewall_default_bridge: "reaches_tailnet"
           }
  end

  test "a marker it can't read is as good as none", %{config: config} do
    mark(config, ["nonsense"])
    assert Firewall.report(config) == %{firewall: "outdated"}

    File.rm!(config.firewall_marker)
    File.mkdir_p!(config.firewall_marker)
    assert Firewall.report(config) == %{firewall: "missing"}
  end

  test "is what the join payload carries", %{config: config, sha: sha} do
    mark(config, ["source_sha256=#{sha}", "default_bridge=filtered"])

    join =
      Map.merge(
        %{
          "agent_version" => "0.1.0",
          "protocol_version" => ForemanProtocol.version(),
          "hostname" => "box-a",
          "os" => "linux",
          "arch" => "x86_64"
        },
        Map.new(Firewall.report(config), fn {k, v} -> {Atom.to_string(k), v} end)
      )

    assert {:ok, %{firewall: "active", firewall_default_bridge: "filtered"}} =
             ForemanProtocol.cast_join(join)
  end

  test "the rules it ships with are the ones in priv" do
    assert File.read!(Config.load().firewall_rules) =~ "table inet foreman"
  end
end
