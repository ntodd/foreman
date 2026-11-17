defmodule ForemanAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Config

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
end
