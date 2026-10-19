defmodule ForemanProtocol.ProtocolV3Test do
  @moduledoc """
  Protocol 3: `env.create` and `env.rebuild` can carry the devcontainer
  features a user adds to their own environments, and `env.rebuild` can
  fast-forward the clone to its branch first (`pull`). GPU reservations
  have their own policy rule, so a box can allow GPUs without allowing
  every host device.
  """
  use ExUnit.Case, async: true

  alias ForemanProtocol.{Command, Feature, Policy}

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  defp create(overrides) do
    Command.new(
      "env.create",
      Map.merge(
        %{
          "env_id" => @env_id,
          "slug" => "storefront-2",
          "repo" => "acme/storefront",
          "clone_url" => "https://github.com/acme/storefront.git",
          "branch" => "main"
        },
        overrides
      )
    )
  end

  defp rebuild(overrides) do
    Command.new(
      "env.rebuild",
      Map.merge(
        %{
          "env_id" => @env_id,
          "slug" => "storefront-2",
          "repo" => "acme/storefront",
          "clone_url" => "https://github.com/acme/storefront.git",
          "branch" => "main"
        },
        overrides
      )
    )
  end

  describe "features" do
    test "carries feature refs and their options" do
      features = %{
        "ghcr.io/ntodd/devcontainer-features/orca:1" => %{"port" => "4100", "server" => true},
        ("ghcr.io/devcontainers/features/node@sha256:" <> String.duplicate("a", 64)) => %{}
      }

      assert {:ok, cmd} = create(%{"features" => features})
      assert cmd.payload.features == features
      assert Command.to_wire(cmd)["payload"]["features"] == features
    end

    test "is absent unless set, so an agent on protocol 2 sees the command it knows" do
      assert {:ok, cmd} = create(%{})
      refute Map.has_key?(cmd.payload, :features)
      refute Map.has_key?(Command.to_wire(cmd)["payload"], "features")
    end

    test "refuses refs that aren't OCI feature refs" do
      for bad <- [
            "./.foreman/feature",
            "../feature",
            "/abs/feature",
            "https://example.com/feature.tgz",
            "node",
            "ghcr.io/Acme/Feature:1",
            "ghcr.io/acme/feature:-1",
            "ghcr.io/acme/feature@sha256:abc",
            "ghcr.io/acme/feature:1 --privileged",
            # What the devcontainer CLI's own parser refuses: one path part,
            # doubled separators, and a tag it would lowercase into another.
            "ghcr.io/x:1",
            "ghcr.io/acme/features/x__y:1",
            "ghcr.io/acme/features/x--y:1",
            "ghcr.io/acme/features/x:ReleaseA"
          ] do
        assert {:error, errors} = create(%{"features" => %{bad => %{}}}),
               "expected #{inspect(bad)} to fail"

        assert Enum.any?(errors, &match?({"features" <> _, _}, &1))
      end
    end

    test "only takes string and boolean option values" do
      for bad <- [1, nil, ["a"], %{"a" => "b"}] do
        features = %{"ghcr.io/acme/features/x:1" => %{"opt" => bad}}
        assert {:error, _} = create(%{"features" => features}), "expected #{inspect(bad)} to fail"
      end
    end
  end

  describe "Feature" do
    test "valid_ref?/1" do
      assert Feature.valid_ref?("ghcr.io/ntodd/devcontainer-features/orca:1")
      assert Feature.valid_ref?("ghcr.io/devcontainers/features/node")
      assert Feature.valid_ref?("localhost:5000/features/x:1.2.3")
      refute Feature.valid_ref?("./.foreman/feature")
      refute Feature.valid_ref?("node")
      refute Feature.valid_ref?(String.duplicate("a", 600) <> ".io/x")
    end

    test "base/1 drops the tag or digest" do
      assert Feature.base("ghcr.io/ntodd/devcontainer-features/orca:1") ==
               "ghcr.io/ntodd/devcontainer-features/orca"

      assert Feature.base("ghcr.io/x/node@sha256:" <> String.duplicate("a", 64)) ==
               "ghcr.io/x/node"

      assert Feature.base("localhost:5000/features/x") == "localhost:5000/features/x"
      assert Feature.base("localhost:5000/features/x:2") == "localhost:5000/features/x"
    end

    test "id/1 is the last part of the ref" do
      assert Feature.id("ghcr.io/ntodd/devcontainer-features/orca:1") == "orca"

      assert Feature.id("ghcr.io/ntodd/foreman/foreman@sha256:" <> String.duplicate("a", 64)) ==
               "foreman"
    end
  end

  describe "pull" do
    test "a rebuild can pull first" do
      assert {:ok, cmd} = rebuild(%{"pull" => true})
      assert cmd.payload.pull == true
    end

    test "is absent unless set, so a protocol 2 agent sees the rebuild it knows" do
      assert {:ok, cmd} = rebuild(%{})
      refute Map.has_key?(cmd.payload, :pull)
      refute Map.has_key?(Command.to_wire(cmd)["payload"], "pull")
    end

    test "only a rebuild pulls" do
      assert {:error, _} = create(%{"pull" => true})
    end
  end

  describe "the gpu policy rule" do
    test "is a rule of its own, refused by default" do
      assert "gpu" in Policy.rules()
      assert Policy.defaults()["gpu"] == "refuse"
      assert Policy.relaxed(%{"gpu" => "allow"}) == [{"gpu", "allow"}]
    end

    test "an agent can report it when it joins" do
      join = %{
        "agent_version" => "0.4.0",
        "protocol_version" => 3,
        "hostname" => "gpu-box",
        "os" => "linux",
        "arch" => "x86_64",
        "policy" => Map.put(Policy.defaults(), "gpu", "allow")
      }

      assert {:ok, %{policy: %{"gpu" => "allow", "devices" => "refuse"}}} =
               ForemanProtocol.cast_join(join)
    end
  end

  test "this build speaks protocol 3 and still accepts agents on 2" do
    assert ForemanProtocol.version() == 3
    assert ForemanProtocol.compatible?(3)
    assert ForemanProtocol.compatible?(2)
    refute ForemanProtocol.compatible?(1)
  end

  describe "the box firewall" do
    @join %{
      "agent_version" => "0.4.0",
      "protocol_version" => 3,
      "hostname" => "desktop",
      "os" => "linux",
      "arch" => "x86_64"
    }

    test "a join can carry its state" do
      for state <- ~w(active outdated missing) do
        assert {:ok, %{firewall: ^state}} =
                 ForemanProtocol.cast_join(Map.put(@join, "firewall", state))
      end
    end

    test "and whether the default bridge reaches the tailnet" do
      for bridge <- ~w(filtered reaches_tailnet) do
        join = Map.merge(@join, %{"firewall" => "active", "firewall_default_bridge" => bridge})
        assert {:ok, %{firewall_default_bridge: ^bridge}} = ForemanProtocol.cast_join(join)
      end
    end

    test "an agent on 2 reports neither" do
      assert {:ok, join} = ForemanProtocol.cast_join(Map.put(@join, "protocol_version", 2))
      refute Map.has_key?(join, :firewall)
      refute Map.has_key?(join, :firewall_default_bridge)
    end

    test "refuses a state it doesn't know" do
      assert {:error, _} = ForemanProtocol.cast_join(Map.put(@join, "firewall", "probably"))

      assert {:error, _} =
               ForemanProtocol.cast_join(Map.put(@join, "firewall_default_bridge", "open"))
    end

    # The agent reports it again when it changes between joins.
    test "box.firewall carries the same, as an event" do
      assert {:ok, %{payload: %{firewall: "missing", firewall_default_bridge: "filtered"}}} =
               ForemanProtocol.Event.new("box.firewall", %{
                 firewall: "missing",
                 firewall_default_bridge: "filtered"
               })

      assert {:ok, %{payload: payload}} =
               ForemanProtocol.Event.new("box.firewall", %{firewall: "active"})

      refute Map.has_key?(payload, :firewall_default_bridge)
      assert {:error, _} = ForemanProtocol.Event.new("box.firewall", %{firewall: "probably"})
      assert {:error, _} = ForemanProtocol.Event.new("box.firewall", %{})
    end

    test "dumps what it casts" do
      join = Map.merge(@join, %{"firewall" => "missing", "firewall_default_bridge" => "filtered"})
      {:ok, cast} = ForemanProtocol.cast_join(join)

      assert %{"firewall" => "missing", "firewall_default_bridge" => "filtered"} =
               ForemanProtocol.dump_join(cast)
    end
  end
end
