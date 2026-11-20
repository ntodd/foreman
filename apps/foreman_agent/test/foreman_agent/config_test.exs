defmodule ForemanAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Config

  describe "devcontainer_cli/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      release = Path.join(tmp, "priv/tools")
      cli = Path.join(release, "bin/devcontainer")
      File.mkdir_p!(Path.dirname(cli))
      File.write!(cli, "#!/bin/sh\n")
      File.chmod!(cli, 0o755)
      %{release: release, cli: cli}
    end

    test "a release runs the devcontainer CLI it carries", c do
      assert Config.devcontainer_cli(c.release, nil) == c.cli
    end

    test "outside a release the CLI comes from PATH" do
      assert Config.devcontainer_cli(nil, nil) == "devcontainer"
    end

    test "a release without tools falls back to PATH rather than a path that isn't there",
         %{tmp_dir: tmp} do
      assert Config.devcontainer_cli(Path.join(tmp, "elsewhere"), nil) == "devcontainer"
    end

    test "an override wins over what the release carries", c do
      assert Config.devcontainer_cli(c.release, "/opt/cli/devcontainer") ==
               "/opt/cli/devcontainer"
    end

    test "an empty override counts as none", c do
      assert Config.devcontainer_cli(c.release, "") == c.cli
    end

    # Install scripts before the bundled CLI installed one with npm and
    # wrote its path into agent.env, which a self-update keeps.
    test "the CLI old install scripts set up gives way to the release's", c do
      legacy = "/opt/foreman-agent/node/node_modules/.bin/devcontainer"

      assert Config.devcontainer_cli(c.release, legacy) == c.cli
      assert Config.devcontainer_cli(nil, legacy) == legacy
    end
  end
end
