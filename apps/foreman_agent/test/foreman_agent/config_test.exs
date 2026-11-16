defmodule ForemanAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Config
  alias ForemanAgent.Env.Policy

  test "a box refuses everything unless it opts out" do
    assert Enum.all?(Policy.default_rules(), fn {_rule, action} -> action == :refuse end)
  end

  test "reports the box's policy in the form the join payload carries" do
    config = %Config{policy_rules: Map.merge(Policy.default_rules(), %{privileged: :allow})}

    report = Config.policy_report(config)
    assert report == Map.put(ForemanProtocol.Policy.defaults(), "privileged", "allow")

    assert {:ok, %{policy: ^report}} =
             ForemanProtocol.cast_join(%{
               "agent_version" => "0.1.0",
               "protocol_version" => ForemanProtocol.version(),
               "hostname" => "box-a",
               "os" => "linux",
               "arch" => "x86_64",
               "policy" => report
             })
  end

  describe "tools/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      release = Path.join(tmp, "priv/tools")
      cli = Path.join(release, "bin/devcontainer")
      node = Path.join(release, "node/bin/node")

      for path <- [cli, node] do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "#!/bin/sh\n")
        File.chmod!(path, 0o755)
      end

      %{release: release, cli: cli, node: node}
    end

    test "a release runs the devcontainer CLI and Node it carries", c do
      assert Config.tools(c.release, %{}) == %{devcontainer: c.cli, node: c.node}
    end

    test "outside a release, both come from PATH" do
      assert Config.tools(nil, %{}) == %{devcontainer: "devcontainer", node: "node"}
    end

    test "a release without tools falls back to PATH rather than a path that isn't there",
         %{tmp_dir: tmp} do
      assert Config.tools(Path.join(tmp, "elsewhere"), %{}) ==
               %{devcontainer: "devcontainer", node: "node"}
    end

    test "an override wins over what the release carries", c do
      assert Config.tools(c.release, %{devcontainer: "/opt/cli/devcontainer", node: "/opt/node"}) ==
               %{devcontainer: "/opt/cli/devcontainer", node: "/opt/node"}
    end

    test "an empty override counts as none", c do
      assert Config.tools(c.release, %{devcontainer: "", node: ""}) ==
               %{devcontainer: c.cli, node: c.node}
    end

    # Install scripts before the bundled CLI installed one with npm and
    # wrote its path into agent.env, which a self-update keeps.
    test "the CLI old install scripts set up gives way to the release's", c do
      legacy = "/opt/foreman-agent/node/node_modules/.bin/devcontainer"

      assert Config.tools(c.release, %{devcontainer: legacy}).devcontainer == c.cli
      assert Config.tools(nil, %{devcontainer: legacy}).devcontainer == legacy
    end
  end

  describe "FOREMAN_POLICY" do
    test "accepts every rule the protocol knows, seccomp included" do
      assert Config.parse_policy(["seccomp=allow", "host_bind=warn"]) == %{
               seccomp: :allow,
               host_bind: :warn
             }

      for rule <- ForemanProtocol.Policy.rules() do
        assert Config.parse_policy(["#{rule}=allow"]) == %{String.to_atom(rule) => :allow}
      end
    end

    test "refuses rules and actions it doesn't know, so a typo can't pass silently" do
      assert_raise ArgumentError, ~r/seccom=allow/, fn ->
        Config.parse_policy(["seccom=allow"])
      end

      assert_raise ArgumentError, ~r/maybe/, fn -> Config.parse_policy(["seccomp=maybe"]) end
    end

    test "a seccomp loosening is reported to the control plane" do
      config = %Config{policy_rules: Map.merge(Policy.default_rules(), %{seccomp: :allow})}
      assert Config.policy_report(config)["seccomp"] == "allow"
    end
  end
end
