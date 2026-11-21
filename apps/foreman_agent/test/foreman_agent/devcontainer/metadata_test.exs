defmodule ForemanAgent.Devcontainer.MetadataTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Metadata

  @label "devcontainer.metadata"

  defp feature_set(user_id, metadata) do
    %{source: %{type: :oci, user_feature_id: user_id}, id: metadata["id"], metadata: metadata}
  end

  describe "from_labels/1" do
    test "reads the entries an image or container carries" do
      assert Metadata.from_labels(%{@label => ~s([{"id":"a"},{"remoteUser":"dev"}])}) ==
               [%{"id" => "a"}, %{"remoteUser" => "dev"}]
    end

    test "takes a single object as one entry" do
      assert Metadata.from_labels(%{@label => ~s({"remoteUser":"dev"})}) == [
               %{"remoteUser" => "dev"}
             ]
    end

    test "is empty without the label, or with one that isn't metadata" do
      assert Metadata.from_labels(%{}) == []
      assert Metadata.from_labels(nil) == []
      assert Metadata.from_labels(%{@label => "not json"}) == []
      assert Metadata.from_labels(%{@label => "42"}) == []
    end
  end

  describe "build/3" do
    test "is the base image's entries, each feature's, then the config's" do
      config = %{
        "image" => "image",
        "name" => "ignored",
        "remoteUser" => "testUser",
        "postCreateCommand" => "make",
        "customizations" => %{"vscode" => %{"extensions" => ["a.b"]}}
      }

      features = [
        feature_set("ghcr.io/my-org/my-repo/someFeature:1", %{
          "id" => "someFeature",
          "version" => "1.2.3",
          "options" => %{"x" => %{"type" => "string"}},
          "containerEnv" => %{"A" => "1"},
          "entrypoint" => "/usr/local/share/some.sh",
          "capAdd" => ["NET_ADMIN"],
          "postStartCommand" => "start"
        })
      ]

      assert Metadata.build([%{"id" => "baseFeature"}], features, config) == [
               %{"id" => "baseFeature"},
               %{
                 "id" => "ghcr.io/my-org/my-repo/someFeature:1",
                 "entrypoint" => "/usr/local/share/some.sh",
                 "capAdd" => ["NET_ADMIN"],
                 "postStartCommand" => "start"
               },
               %{
                 "remoteUser" => "testUser",
                 "postCreateCommand" => "make",
                 "customizations" => %{"vscode" => %{"extensions" => ["a.b"]}}
               }
             ]
    end

    test "leaves out entries with nothing in them" do
      assert Metadata.build([], [], %{"image" => "image"}) == []
    end

    test "moves a feature's old extensions and settings into its customizations" do
      feature =
        feature_set("./local", %{
          "id" => "local",
          "extensions" => ["a.b"],
          "settings" => %{"x" => 1, "y" => 1},
          "customizations" => %{"vscode" => %{"extensions" => ["c.d"], "settings" => %{"y" => 2}}}
        })

      assert Metadata.build([], [feature], %{}) == [
               %{
                 "id" => "./local",
                 "customizations" => %{
                   "vscode" => %{
                     "extensions" => ["c.d", "a.b"],
                     "settings" => %{"x" => 1, "y" => 2}
                   }
                 }
               }
             ]
    end
  end

  describe "label/1" do
    test "is a Dockerfile LABEL, one entry a line, with quotes, backslashes and dollars escaped" do
      entries = [
        %{"id" => "baseFeature"},
        %{"id" => "ghcr.io/o/r/f:1", "entrypoint" => "/x.sh", "capAdd" => ["NET_ADMIN"]},
        %{"remoteUser" => "testUser", "postCreateCommand" => ~S(echo "$HOME" \ done)}
      ]

      expected = ~S"""
      LABEL devcontainer.metadata="[ \
      {\"id\":\"baseFeature\"}, \
      {\"id\":\"ghcr.io/o/r/f:1\",\"capAdd\":[\"NET_ADMIN\"],\"entrypoint\":\"/x.sh\"}, \
      {\"postCreateCommand\":\"echo \\\"\$HOME\\\" \\\\ done\",\"remoteUser\":\"testUser\"} \
      ]"
      """

      assert Metadata.label(entries) == String.trim_trailing(expected, "\n")
    end

    test "is nothing without entries" do
      assert Metadata.label([]) == ""
    end
  end

  describe "label_value/1" do
    test "is the entries as the JSON a container label holds" do
      assert Metadata.label_value([%{"remoteUser" => "dev", "id" => "x"}]) ==
               ~s([{"id":"x","remoteUser":"dev"}])
    end
  end

  describe "merge/2" do
    test "merges what the image, the features and the config each say" do
      config = %{
        "image" => "image",
        "remoteUser" => "configUser",
        "postCreateCommand" => "config",
        "entrypoint" => "ignored",
        "customizations" => %{}
      }

      entries = [
        %{
          "id" => "feature1",
          "init" => true,
          "capAdd" => ["A", "B"],
          "securityOpt" => ["x"],
          "entrypoint" => "one.sh",
          "mounts" => [
            "type=volume,source=one,target=/data",
            %{"type" => "bind", "source" => "/a", "target" => "/b"}
          ],
          "containerEnv" => %{"A" => "1", "B" => "1"},
          "remoteEnv" => %{"R" => "1"},
          "postCreateCommand" => "feature1",
          "remoteUser" => "featureUser",
          "overrideCommand" => true,
          "updateRemoteUserUID" => true
        },
        %{
          "id" => "feature2",
          "privileged" => true,
          "capAdd" => ["B", "C"],
          "entrypoint" => "two.sh",
          "mounts" => ["type=volume,src=two,dst=/data"],
          "postCreateCommand" => %{"a" => "feature2"},
          "onCreateCommand" => ["echo", "hi"]
        },
        %{
          "containerEnv" => %{"B" => "2"},
          "remoteEnv" => %{"R" => "2", "S" => nil},
          "remoteUser" => "configUser",
          "containerUser" => "root",
          "userEnvProbe" => "loginShell",
          "waitFor" => "postCreateCommand",
          "postCreateCommand" => "config",
          "overrideCommand" => false,
          "updateRemoteUserUID" => false
        }
      ]

      merged = Metadata.merge(config, entries)

      assert merged["image"] == "image"
      refute Map.has_key?(merged, "postCreateCommand")
      refute Map.has_key?(merged, "entrypoint")

      assert merged["init"] == true
      assert merged["privileged"] == true
      assert merged["capAdd"] == ["A", "B", "C"]
      assert merged["securityOpt"] == ["x"]
      assert merged["entrypoints"] == ["one.sh", "two.sh"]

      assert merged["mounts"] == [
               %{"type" => "bind", "source" => "/a", "target" => "/b"},
               "type=volume,src=two,dst=/data"
             ]

      assert merged["containerEnv"] == %{"A" => "1", "B" => "2"}
      assert merged["remoteEnv"] == %{"R" => "2", "S" => nil}
      assert merged["remoteUser"] == "configUser"
      assert merged["containerUser"] == "root"
      assert merged["userEnvProbe"] == "loginShell"
      assert merged["waitFor"] == "postCreateCommand"
      assert merged["overrideCommand"] == false
      assert merged["updateRemoteUserUID"] == false
      assert merged["onCreateCommands"] == [["echo", "hi"]]
      assert merged["postCreateCommands"] == ["feature1", %{"a" => "feature2"}, "config"]
      assert merged["postStartCommands"] == []
    end

    test "with nothing to merge" do
      merged = Metadata.merge(%{"service" => "app"}, [])

      assert merged["service"] == "app"
      assert merged["init"] == false
      assert merged["privileged"] == false
      assert merged["capAdd"] == nil
      assert merged["entrypoints"] == nil
      assert merged["mounts"] == nil
      assert merged["containerEnv"] == %{}
      assert merged["remoteUser"] == nil
      assert merged["overrideCommand"] == nil
    end
  end

  describe "parse_mount/1" do
    test "reads a mount string, whichever names it uses" do
      assert Metadata.parse_mount("type=volume,src=two,dst=/data") ==
               %{"type" => "volume", "source" => "two", "target" => "/data"}

      assert Metadata.parse_mount("source=/a,destination=/b,type=bind,external=true") ==
               %{"type" => "bind", "source" => "/a", "target" => "/b", "external" => "true"}

      assert Metadata.parse_mount(%{"type" => "bind", "target" => "/b"}) == %{
               "type" => "bind",
               "target" => "/b"
             }
    end
  end

  describe "from_container/3" do
    @config %{
      "service" => "app",
      "remoteUser" => "dev",
      "postCreateCommand" => "make",
      "userEnvProbe" => "none"
    }

    test "a container without the label gets the config's entry alone" do
      assert Metadata.from_container(%{"Config" => %{"Labels" => %{}}}, @config, [
               "foreman.env_id=1"
             ]) ==
               [%{"remoteUser" => "dev", "postCreateCommand" => "make", "userEnvProbe" => "none"}]

      assert Metadata.from_container(%{"Config" => %{"Labels" => nil}}, @config, []) ==
               [%{"remoteUser" => "dev", "postCreateCommand" => "make", "userEnvProbe" => "none"}]
    end

    test "a container made with the id labels keeps its entries, and only what can change comes from the config" do
      container = %{
        "Config" => %{
          "Labels" => %{
            "foreman.env_id" => "1",
            @label =>
              ~s([{"id":"f","postCreateCommand":"feature"},{"postCreateCommand":"old","remoteUser":"old"}])
          }
        }
      }

      assert Metadata.from_container(container, @config, ["foreman.env_id=1"]) == [
               %{"id" => "f", "postCreateCommand" => "feature"},
               %{"postCreateCommand" => "old", "remoteUser" => "old"},
               %{"remoteUser" => "dev", "userEnvProbe" => "none"}
             ]
    end

    test "a container without the id labels gets the whole config's entry on top" do
      container = %{"Config" => %{"Labels" => %{@label => ~s([{"id":"f"}])}}}

      assert Metadata.from_container(container, @config, ["foreman.env_id=1"]) == [
               %{"id" => "f"},
               %{"remoteUser" => "dev", "postCreateCommand" => "make", "userEnvProbe" => "none"}
             ]
    end
  end

  describe "lifecycle_origins/1" do
    test "lists each hook's commands in order, with where they came from" do
      entries = [
        %{"id" => "ghcr.io/o/r/f:1", "postCreateCommand" => "feature", "onCreateCommand" => ""},
        %{"postCreateCommand" => %{"a" => "x"}, "postStartCommand" => ["start"]}
      ]

      assert Metadata.lifecycle_origins(entries) == %{
               "onCreateCommand" => [],
               "updateContentCommand" => [],
               "postCreateCommand" => [
                 {"ghcr.io/o/r/f:1", "feature"},
                 {"devcontainer.json", %{"a" => "x"}}
               ],
               "postStartCommand" => [{"devcontainer.json", ["start"]}],
               "postAttachCommand" => []
             }
    end
  end
end
