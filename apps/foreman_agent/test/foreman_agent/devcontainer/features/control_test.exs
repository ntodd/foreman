defmodule ForemanAgent.Devcontainer.Features.ControlTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Features.Control

  @moduletag :tmp_dir

  @manifest %{
    "disallowedFeatures" => [
      %{
        "featureIdPrefix" => "ghcr.io/bad/features/evil",
        "documentationURL" => "https://example.com/evil"
      },
      %{"featureIdPrefix" => "ghcr.io/worse"},
      %{"nonsense" => true}
    ],
    "featureAdvisories" => [
      %{
        "featureId" => "ghcr.io/o/features/hello",
        "introducedInVersion" => "1.0.7",
        "fixedInVersion" => "1.1.10",
        "description" => "It says goodbye.",
        "documentationURL" => "https://example.com/hello"
      },
      %{
        "featureId" => "ghcr.io/o/features/hello",
        "introducedInVersion" => "2.0.0",
        "fixedInVersion" => "2.0.1",
        "description" => "Another."
      },
      %{"featureId" => "incomplete"}
    ]
  }

  defp fetched(manifest \\ @manifest) do
    test_pid = self()

    fn ->
      send(test_pid, :fetched)
      {:ok, JSON.encode!(manifest)}
    end
  end

  describe "load/2" do
    test "fetches the manifest and keeps a copy", %{tmp_dir: tmp} do
      path = Path.join(tmp, "cache/control-manifest.json")

      manifest = Control.load(path, fetched())

      assert_received :fetched
      assert length(manifest.disallowed) == 2
      assert length(manifest.advisories) == 2
      assert File.exists?(path)
    end

    test "uses the copy for five minutes", %{tmp_dir: tmp} do
      path = Path.join(tmp, "control-manifest.json")
      first = Control.load(path, fetched())
      assert_received :fetched

      assert Control.load(path, fetched(%{})) == first
      refute_received :fetched

      File.touch!(path, System.os_time(:second) - 301)
      assert Control.load(path, fetched(%{})) == %{disallowed: [], advisories: []}
      assert_received :fetched
    end

    test "falls back to an old copy, or to nothing, when it can't be fetched", %{tmp_dir: tmp} do
      path = Path.join(tmp, "control-manifest.json")
      unreachable = fn -> {:error, "no route"} end

      assert Control.load(path, unreachable) == %{disallowed: [], advisories: []}

      first = Control.load(Path.join(tmp, "other.json"), fetched())
      File.touch!(Path.join(tmp, "other.json"), System.os_time(:second) - 301)
      assert Control.load(Path.join(tmp, "other.json"), unreachable) == first
    end

    test "something that isn't a manifest is nothing", %{tmp_dir: tmp} do
      assert Control.load(Path.join(tmp, "a.json"), fn -> {:ok, "<html>"} end) == %{
               disallowed: [],
               advisories: []
             }

      assert Control.load(Path.join(tmp, "b.json"), fn -> {:ok, "[1]"} end) == %{
               disallowed: [],
               advisories: []
             }
    end
  end

  describe "disallowed/2" do
    setup %{tmp_dir: tmp} do
      %{manifest: Control.load(Path.join(tmp, "m.json"), fetched())}
    end

    test "is the first feature the manifest disallows, at any version", %{manifest: manifest} do
      assert Control.disallowed(manifest, [
               "ghcr.io/o/features/fine:1",
               "ghcr.io/bad/features/evil:2"
             ]) ==
               %{id: "ghcr.io/bad/features/evil:2", documentation_url: "https://example.com/evil"}

      assert %{id: "ghcr.io/bad/features/evil"} =
               Control.disallowed(manifest, ["ghcr.io/bad/features/evil"])

      assert %{id: "ghcr.io/bad/features/evil@sha256:abc"} =
               Control.disallowed(manifest, ["ghcr.io/bad/features/evil@sha256:abc"])

      assert %{documentation_url: nil} =
               Control.disallowed(manifest, ["ghcr.io/worse/features/x:1"])
    end

    test "a prefix isn't a feature that only starts the same", %{manifest: manifest} do
      assert Control.disallowed(manifest, [
               "ghcr.io/bad/features/evil-twin:1",
               "ghcr.io/worse-not/x"
             ]) == nil

      assert Control.disallowed(manifest, []) == nil
    end
  end

  describe "advisories/2" do
    setup %{tmp_dir: tmp} do
      %{manifest: Control.load(Path.join(tmp, "m.json"), fetched())}
    end

    defp set(resource, version) do
      [registry | path] = String.split(resource, "/")

      %{
        source: %{type: :oci, ref: %{registry: registry, path: Enum.join(path, "/")}},
        metadata: %{"version" => version}
      }
    end

    test "names the features at a version an advisory covers", %{manifest: manifest} do
      assert [
               %{
                 id: "ghcr.io/o/features/hello",
                 version: "1.1.9",
                 advisories: [%{"description" => "It says goodbye."}]
               }
             ] =
               Control.advisories(manifest, [
                 set("ghcr.io/o/features/hello", "1.1.9"),
                 set("ghcr.io/o/features/other", "1.1.9")
               ])

      assert [_] = Control.advisories(manifest, [set("ghcr.io/o/features/hello", "1.0.7")])
    end

    test "not ones from before it, or with the fix", %{manifest: manifest} do
      assert Control.advisories(manifest, [set("ghcr.io/o/features/hello", "1.0.6")]) == []
      assert Control.advisories(manifest, [set("ghcr.io/o/features/hello", "1.1.10")]) == []
      assert Control.advisories(manifest, [set("ghcr.io/o/features/hello", "nonsense")]) == []

      assert Control.advisories(manifest, [
               %{source: %{type: :file_path}, metadata: %{"version" => "1.1.0"}}
             ]) == []
    end

    test "as text for the log", %{manifest: manifest} do
      [found] = Control.advisories(manifest, [set("ghcr.io/o/features/hello", "1.1.0")])

      assert Control.describe([found]) ==
               "Feature advisories:\n" <>
                 "- ghcr.io/o/features/hello:1.1.0: It says goodbye. (introduced in 1.0.7, fixed in 1.1.10, see https://example.com/hello)\n" <>
                 "Update these features to versions with the fixes.\n"
    end
  end
end
