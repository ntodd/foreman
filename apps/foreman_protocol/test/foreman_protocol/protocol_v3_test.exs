defmodule ForemanProtocol.ProtocolV3Test do
  @moduledoc """
  Protocol 3: `env.create` and `env.rebuild` can carry the devcontainer
  features a user adds to their own environments, and `env.rebuild` can
  fast-forward the clone to its branch first (`pull`).
  """
  use ExUnit.Case, async: true

  alias ForemanProtocol.{Command, Feature}

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

  test "this build speaks protocol 3 and still accepts agents on 2" do
    assert ForemanProtocol.version() == 3
    assert ForemanProtocol.compatible?(3)
    assert ForemanProtocol.compatible?(2)
    refute ForemanProtocol.compatible?(1)
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
end
