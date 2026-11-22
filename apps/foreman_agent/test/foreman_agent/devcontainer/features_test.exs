defmodule ForemanAgent.Devcontainer.FeaturesTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Features
  alias ForemanAgent.Devcontainer.Features.Registry
  alias ForemanAgent.Test.FakeRegistry

  @moduletag :tmp_dir

  @fixture Path.expand("../../fixtures/devcontainer/oracle/project/devcontainer", __DIR__)

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "proj")
    File.mkdir_p!(workspace)
    File.cp_r!(@fixture, Path.join(workspace, ".devcontainer"))
    test_pid = self()

    opts = [
      workspace: workspace,
      config_path: Path.join(workspace, ".devcontainer/devcontainer.json"),
      registry: Registry.new(),
      log: fn text -> send(test_pid, {:feature_log, text}) end
    ]

    %{workspace: workspace, dst: Path.join(tmp, "build"), opts: opts}
  end

  defp config(features), do: %{"features" => features}

  defp local_feature(workspace, name, metadata, files \\ %{}) do
    dir = Path.join([workspace, ".devcontainer", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "devcontainer-feature.json"), JSON.encode!(metadata))
    File.write!(Path.join(dir, "install.sh"), "#!/bin/sh\n")
    for {file, content} <- files, do: File.write!(Path.join(dir, file), content)
    dir
  end

  describe "user_features/2" do
    test "is the config's features, then the additional ones it doesn't have" do
      assert Features.user_features(%{"./a" => %{"x" => 1}, "ghcr.io/o/f/b:1" => "2"}, %{
               "./a" => %{},
               "./c" => true
             })
             |> Enum.sort() == [{"./a", %{"x" => 1}}, {"./c", true}, {"ghcr.io/o/f/b:1", "2"}]
    end

    test "folds features that became options into the feature that has them now" do
      assert Features.user_features(
               %{"gradle" => true, "ghcr.io/devcontainers/features/java:1" => "17"},
               %{}
             ) ==
               [
                 {"ghcr.io/devcontainers/features/java:1",
                  %{"version" => "17", "installGradle" => true}}
               ]

      assert Features.user_features(%{"jupyterlab" => true}, %{}) ==
               [{"ghcr.io/devcontainers/features/python:1", %{"installJupyterlab" => true}}]
    end
  end

  describe "modern_id/1" do
    test "maps the short names features once had to where they are now" do
      assert Features.modern_id("git") == "ghcr.io/devcontainers/features/git:1"
      assert Features.modern_id("golang") == "ghcr.io/devcontainers/features/go:1"
      assert Features.modern_id("common") == "ghcr.io/devcontainers/features/common-utils:1"
      assert Features.modern_id("ghcr.io/o/features/git") == "ghcr.io/o/features/git"
      assert Features.modern_id("fish") == "fish"
    end
  end

  describe "prepare/4 with local features" do
    test "puts each feature's files in the build folder, in install order", %{
      dst: dst,
      opts: opts
    } do
      features = %{
        "./local-feature" => %{"greeting" => "hi there", "loud" => true},
        "./second" => %{}
      }

      assert {:ok, [second, local]} = Features.prepare(config(features), %{}, dst, opts)

      assert second.id == "second"
      assert second.consecutive_id == "second_0"
      assert second.cache_path == Path.join(dst, "second_0")

      assert second.source == %{
               type: :file_path,
               user_feature_id: "./second",
               resolved_path: Path.join(opts[:workspace], ".devcontainer/second")
             }

      assert local.id == "local-feature"
      assert local.consecutive_id == "local-feature_1"
      assert local.value == %{"greeting" => "hi there", "loud" => true}
      assert local.metadata["name"] == "Local 'Feature'"
      assert local.metadata["entrypoint"] == "/usr/local/share/local-entry.sh"
      assert local.order["options"] == ["zeta", "greeting", "loud"]
      assert local.order["containerEnv"] == ["ZED_HOME", "PATH", "QUOTED"]
      # A local feature goes by what the config called it until its own file names it.
      assert second.metadata["name"] == "./second"

      assert File.read!(Path.join(dst, "local-feature_1/install.sh")) ==
               File.read!(Path.join(@fixture, "local-feature/install.sh"))

      assert File.exists?(Path.join(dst, "second_0/devcontainer-feature.json"))
    end

    test "is nothing without features", %{dst: dst, opts: opts} do
      assert Features.prepare(%{}, %{}, dst, opts) == {:ok, []}
      assert Features.prepare(config(%{}), %{}, dst, opts) == {:ok, []}
    end

    test "adds the additional features", %{dst: dst, opts: opts} do
      assert {:ok, [%{id: "second", value: %{"x" => true}}]} =
               Features.prepare(%{}, %{"./second" => %{"x" => true}}, dst, opts)
    end

    test "installs features in the order the config overrides", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      local_feature(workspace, "aaa", %{"id" => "aaa"})
      local_feature(workspace, "bbb", %{"id" => "bbb"})

      config = %{
        "features" => %{"./aaa" => %{}, "./bbb" => %{}},
        "overrideFeatureInstallOrder" => ["./bbb"]
      }

      assert {:ok, [%{id: "bbb"}, %{id: "aaa"}]} = Features.prepare(config, %{}, dst, opts)
    end

    test "copies a feature's files as they are, modes included", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      dir = local_feature(workspace, "modes", %{"id" => "modes"})
      File.write!(Path.join(dir, "tool"), String.duplicate("x", 200_000))
      File.chmod!(Path.join(dir, "tool"), 0o750)

      assert {:ok, [_]} = Features.prepare(config(%{"./modes" => %{}}), %{}, dst, opts)

      assert File.read!(Path.join(dst, "modes_0/tool")) == String.duplicate("x", 200_000)
      assert Bitwise.band(File.stat!(Path.join(dst, "modes_0/tool")).mode, 0o777) == 0o750
    end

    test "copies a feature's links as links, never what they point at", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      dir = local_feature(workspace, "linked", %{"id" => "linked"})
      File.ln_s!("/etc/hosts", Path.join(dir, "hosts"))

      assert {:ok, [_]} = Features.prepare(config(%{"./linked" => %{}}), %{}, dst, opts)
      assert {:ok, "/etc/hosts"} = File.read_link(Path.join(dst, "linked_0/hosts"))
    end

    test "refuses a feature that isn't under the devcontainer folder", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      File.mkdir_p!(Path.join(workspace, "elsewhere"))

      assert Features.prepare(config(%{"../elsewhere" => %{}}), %{}, dst, opts) ==
               {:error, "the feature ../elsewhere has to be in the repo's .devcontainer folder"}

      assert Features.prepare(config(%{"/etc" => %{}}), %{}, dst, opts) ==
               {:error,
                "the feature /etc is an absolute path; a local feature is relative to the devcontainer.json"}

      File.ln_s!("/etc", Path.join(workspace, ".devcontainer/outside"))

      assert Features.prepare(config(%{"./outside" => %{}}), %{}, dst, opts) ==
               {:error, "the feature ./outside leads out of the repo"}
    end

    test "takes a feature from another folder it's told features may be in", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      # A devcontainer.json at the repo's root, with a feature beside it.
      dir = Path.join(workspace, ".foreman/feature")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "devcontainer-feature.json"), ~s({"id":"foreman"}))
      File.write!(Path.join(dir, "install.sh"), "#!/bin/sh\n")
      opts = Keyword.put(opts, :config_path, Path.join(workspace, ".devcontainer.json"))

      assert Features.prepare(%{}, %{"./.foreman/feature" => %{}}, dst, opts) ==
               {:error,
                "the feature ./.foreman/feature has to be in the repo's .devcontainer folder"}

      assert {:ok, [%{id: "foreman"}]} =
               Features.prepare(
                 %{},
                 %{"./.foreman/feature" => %{}},
                 dst,
                 Keyword.put(opts, :local_roots, [".foreman"])
               )

      # Still nowhere else.
      File.mkdir_p!(Path.join(workspace, "elsewhere"))

      assert {:error, _} =
               Features.prepare(
                 %{},
                 %{"./elsewhere" => %{}},
                 dst,
                 Keyword.put(opts, :local_roots, [".foreman"])
               )
    end

    test "says what's wrong with a feature it can't use", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      assert Features.prepare(config(%{"./missing" => %{}}), %{}, dst, opts) ==
               {:error, "the feature ./missing has no devcontainer-feature.json"}

      dir = local_feature(workspace, "broken", %{})
      File.write!(Path.join(dir, "devcontainer-feature.json"), "{nope")

      assert {:error, "the feature ./broken's devcontainer-feature.json: invalid JSON" <> _} =
               Features.prepare(config(%{"./broken" => %{}}), %{}, dst, opts)

      assert {:error, "the feature fish" <> _ = message} =
               Features.prepare(config(%{"fish" => %{}}), %{}, dst, opts)

      assert message =~ "containers.dev/features"
    end

    # The id names the folder a feature is laid out in, which is emptied first.
    test "refuses a feature whose own id isn't a plain name", %{
      workspace: workspace,
      dst: dst,
      opts: opts,
      tmp_dir: tmp
    } do
      victim = Path.join(tmp, "victim_0")
      File.mkdir_p!(victim)
      File.write!(Path.join(victim, "keep"), "me")

      for id <- ["../victim", "a/b", "..", ".hidden", "", "with space"] do
        local_feature(workspace, "odd", %{"id" => id})

        assert Features.prepare(config(%{"./odd" => %{}}), %{}, dst, opts) ==
                 {:error,
                  "the feature ./odd calls itself #{inspect(id)}, which isn't a name a feature can have"}
      end

      assert File.read!(Path.join(victim, "keep")) == "me"
    end

    test "gives up when there's no time left", %{dst: dst, opts: opts} do
      opts = Keyword.put(opts, :deadline, System.monotonic_time(:millisecond) - 1)

      assert Features.prepare(config(%{"./second" => %{}}), %{}, dst, opts) ==
               {:error, "there was no time left to get the feature ./second"}
    end

    test "features that wait on each other are an error", %{
      workspace: workspace,
      dst: dst,
      opts: opts
    } do
      local_feature(workspace, "one", %{"id" => "one", "installsAfter" => ["./two"]})
      local_feature(workspace, "two", %{"id" => "two", "installsAfter" => ["./one"]})

      assert Features.prepare(config(%{"./one" => %{}, "./two" => %{}}), %{}, dst, opts) ==
               {:error,
                "the features ./one, ./two depend on each other, or on a feature that can't be installed"}
    end
  end

  describe "prepare/4 with features from a registry" do
    setup %{opts: opts} do
      registry = FakeRegistry.start()
      %{registry: registry, opts: opts}
    end

    test "an independent personal feature keeps the repo's cached layer prefix", ctx do
      %{registry: registry, dst: dst, opts: opts} = ctx

      for {org, id} <- [{"team", "base"}, {"team", "app"}, {"alice", "tool"}] do
        metadata = %{"id" => id, "version" => "1.0.0"}

        metadata =
          if id == "app",
            do: Map.put(metadata, "dependsOn", %{"#{registry.host}/team/features/base:1" => %{}}),
            else: metadata

        FakeRegistry.put_feature(registry, "#{org}/features/#{id}", "1", metadata)
      end

      config = config(%{"#{registry.host}/team/features/app:1" => %{}})
      {:ok, prebuild} = Features.prepare(config, %{}, dst, opts)

      {:ok, personal} =
        Features.prepare(config, %{"#{registry.host}/alice/features/tool:1" => %{}}, dst, opts)

      assert Enum.map(prebuild, & &1.consecutive_id) == ["base_0", "app_1"]
      assert Enum.map(personal, & &1.consecutive_id) == ["base_0", "app_1", "tool_2"]
    end

    test "downloads a feature and unpacks it", %{registry: registry, dst: dst, opts: opts} do
      metadata = %{
        "id" => "hello",
        "version" => "1.2.3",
        "name" => "Hello",
        "options" => %{
          "b" => %{"type" => "string", "default" => "x"},
          "a" => %{"type" => "boolean"}
        },
        "containerEnv" => %{"Z" => "1", "A" => "${Z}"}
      }

      # As written: a map's keys would come out sorted.
      feature_json =
        ~s({"id":"hello","version":"1.2.3","name":"Hello",) <>
          ~s("options":{"b":{"type":"string","default":"x"},"a":{"type":"boolean"}},) <>
          ~s("containerEnv":{"Z":"1","A":"${Z}"}})

      digest =
        FakeRegistry.put_feature(
          registry,
          "org/features/hello",
          "1",
          metadata,
          %{"lib/x.sh" => "x"},
          feature_json: feature_json
        )

      id = "#{registry.host}/org/features/hello:1"

      assert {:ok, [set]} = Features.prepare(config(%{id => %{"b" => "y"}}), %{}, dst, opts)

      assert set.id == "hello"
      assert set.consecutive_id == "hello_0"
      assert set.computed_digest == digest
      assert set.source.type == :oci
      assert set.source.user_feature_id == id
      assert set.source.user_feature_id_without_version == "#{registry.host}/org/features/hello"
      assert set.source.manifest_digest == digest
      assert set.metadata["version"] == "1.2.3"
      assert set.order["options"] == ["b", "a"]
      assert set.order["containerEnv"] == ["Z", "A"]
      assert File.read!(Path.join(dst, "hello_0/lib/x.sh")) == "x"
      assert File.read!(Path.join(dst, "hello_0/install.sh")) =~ "installed"
    end

    test "installs what a feature depends on first, with the options it asks for", %{
      registry: registry,
      dst: dst,
      opts: opts
    } do
      base = "#{registry.host}/org/features/base"

      FakeRegistry.put_feature(registry, "org/features/base", "latest", %{
        "id" => "base",
        "version" => "1.0.0"
      })

      FakeRegistry.put_feature(registry, "org/features/app", "1", %{
        "id" => "app",
        "version" => "2.0.0",
        "dependsOn" => %{base => %{"flavor" => "slim"}}
      })

      assert {:ok, [first, second]} =
               Features.prepare(
                 config(%{"#{registry.host}/org/features/app:1" => %{}}),
                 %{},
                 dst,
                 opts
               )

      assert {first.id, first.value, first.consecutive_id} ==
               {"base", %{"flavor" => "slim"}, "base_0"}

      assert {second.id, second.consecutive_id} == {"app", "app_1"}
    end

    test "installs a feature after the ones it names, when they're being installed", %{
      registry: registry,
      dst: dst,
      opts: opts
    } do
      FakeRegistry.put_feature(registry, "org/features/aaa", "1", %{
        "id" => "aaa",
        "installsAfter" => [
          "#{registry.host}/org/features/zzz",
          "#{registry.host}/org/features/unpublished"
        ]
      })

      FakeRegistry.put_feature(registry, "org/features/zzz", "latest", %{"id" => "zzz"})
      FakeRegistry.put_feature(registry, "org/features/zzz", "2", %{"id" => "zzz"})

      features = %{
        "#{registry.host}/org/features/aaa:1" => %{},
        "#{registry.host}/org/features/zzz:2" => %{}
      }

      assert {:ok, [%{id: "zzz"}, %{id: "aaa"}]} =
               Features.prepare(config(features), %{}, dst, opts)
    end

    test "reads a feature's file when its manifest doesn't carry what's in it", %{
      registry: registry,
      dst: dst,
      opts: opts
    } do
      FakeRegistry.put_feature(registry, "org/features/base", "latest", %{"id" => "base"})

      FakeRegistry.put_feature(
        registry,
        "org/features/old",
        "1",
        %{"id" => "old", "dependsOn" => %{"#{registry.host}/org/features/base" => %{}}},
        %{},
        annotation: false
      )

      assert {:ok, [%{id: "base"}, %{id: "old"}]} =
               Features.prepare(
                 config(%{"#{registry.host}/org/features/old:1" => %{}}),
                 %{},
                 dst,
                 opts
               )
    end

    test "pulls the manifest a lock file pins", %{registry: registry, dst: dst, opts: opts} do
      locked =
        FakeRegistry.put_feature(registry, "org/features/hello", "1.0.0", %{
          "id" => "hello",
          "version" => "1.0.0"
        })

      FakeRegistry.put_feature(registry, "org/features/hello", "1", %{
        "id" => "hello",
        "version" => "1.9.0"
      })

      id = "#{registry.host}/org/features/hello:1"

      lockfile = %{
        "features" => %{id => %{"version" => "1.0.0", "resolved" => "x", "integrity" => locked}}
      }

      assert {:ok, [%{computed_digest: ^locked, metadata: %{"version" => "1.0.0"}}]} =
               Features.prepare(
                 config(%{id => %{}}),
                 %{},
                 dst,
                 Keyword.put(opts, :lockfile, lockfile)
               )
    end

    test "a feature the registry doesn't have is an error", %{
      registry: registry,
      dst: dst,
      opts: opts
    } do
      id = "#{registry.host}/org/features/nope:1"

      assert Features.prepare(config(%{id => %{}}), %{}, dst, opts) ==
               {:error,
                "couldn't find the feature #{id}. It may not exist, or this environment may not have access to it"}
    end

    test "a feature whose archive would write outside its folder is refused", %{
      registry: registry,
      dst: dst,
      opts: opts
    } do
      layer =
        FakeRegistry.tar(%{"../escaped" => "x", "devcontainer-feature.json" => ~s({"id":"evil"})})

      FakeRegistry.put_feature(registry, "org/features/evil", "1", %{"id" => "evil"}, %{},
        archive: layer
      )

      assert {:error, "couldn't unpack the feature " <> _} =
               Features.prepare(
                 config(%{"#{registry.host}/org/features/evil:1" => %{}}),
                 %{},
                 dst,
                 opts
               )

      refute File.exists?(Path.join(dst, "escaped"))
      refute File.exists?(Path.join(Path.dirname(dst), "escaped"))
    end
  end

  describe "prepare/4 with a feature from a URL" do
    test "downloads and unpacks the archive, without its dotfiles", %{dst: dst, opts: opts} do
      url = "https://example.com/releases/devcontainer-feature-hello.tgz"

      archive =
        FakeRegistry.tar(
          %{
            "devcontainer-feature.json" => ~s({"id":"hello","version":"3.0.0"}),
            "install.sh" => "#!/bin/sh\n",
            ".hidden" => "x"
          },
          [:compressed]
        )

      opts = Keyword.put(opts, :fetch_url, fn ^url, _headers -> {:ok, archive} end)

      assert {:ok, [set]} = Features.prepare(config(%{url => %{}}), %{}, dst, opts)

      assert set.id == "hello"
      assert set.source == %{type: :tarball, user_feature_id: url, uri: url}
      assert set.computed_digest == FakeRegistry.digest(archive)
      assert File.exists?(Path.join(dst, "hello_0/install.sh"))
      refute File.exists?(Path.join(dst, "hello_0/.hidden"))
    end

    test "checks the archive against the lock file", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      archive =
        FakeRegistry.tar(%{"devcontainer-feature.json" => ~s({"id":"hello"})}, [:compressed])

      lockfile = %{
        "features" => %{url => %{"integrity" => "sha256:" <> String.duplicate("0", 64)}}
      }

      opts =
        opts
        |> Keyword.put(:fetch_url, fn ^url, _headers -> {:ok, archive} end)
        |> Keyword.put(:lockfile, lockfile)

      assert Features.prepare(config(%{url => %{}}), %{}, dst, opts) ==
               {:error, "the feature #{url} isn't what the lock file says it is"}
    end

    test "sends a GitHub token to GitHub, and to nobody else", %{dst: dst, opts: opts} do
      test_pid = self()

      archive =
        FakeRegistry.tar(%{"devcontainer-feature.json" => ~s({"id":"hello"})}, [:compressed])

      opts =
        opts
        |> Keyword.put(:github_token, "ghp_x")
        |> Keyword.put(:fetch_url, fn url, headers ->
          send(test_pid, {:fetched, url, headers})
          {:ok, archive}
        end)

      github = "https://github.com/o/r/releases/download/v1/devcontainer-feature-hello.tgz"
      other = "https://github.com.example.com/devcontainer-feature-hello.tgz"

      assert {:ok, [_]} = Features.prepare(config(%{github => %{}}), %{}, dst, opts)
      assert_received {:fetched, ^github, headers}
      assert {"authorization", "Bearer ghp_x"} in headers

      assert {:ok, [_]} = Features.prepare(config(%{other => %{}}), %{}, dst, opts)
      assert_received {:fetched, ^other, headers}
      refute Enum.any?(headers, fn {name, _} -> name == "authorization" end)
    end

    test "won't unpack an archive that's far bigger than it looks", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      archive =
        FakeRegistry.tar(
          %{
            "devcontainer-feature.json" => ~s({"id":"hello"}),
            "zeros" => String.duplicate(<<0>>, 2_000_000)
          },
          [:compressed]
        )

      assert byte_size(archive) < 20_000

      opts =
        opts
        |> Keyword.put(:fetch_url, fn ^url, _headers -> {:ok, archive} end)
        |> Keyword.put(:max_unpacked_bytes, 1_000_000)

      assert Features.prepare(config(%{url => %{}}), %{}, dst, opts) ==
               {:error,
                "couldn't unpack the feature #{url}: it's larger than Foreman unpacks (1000000 bytes)"}
    end

    test "unpacks an archive gzipped in several parts", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      tar =
        FakeRegistry.tar(%{
          "devcontainer-feature.json" => ~s({"id":"hello"}),
          "install.sh" => String.duplicate("x", 5000)
        })

      {first, second} = :erlang.split_binary(tar, 1024)
      archive = :zlib.gzip(first) <> :zlib.gzip(second)
      opts = Keyword.put(opts, :fetch_url, fn ^url, _headers -> {:ok, archive} end)

      assert {:ok, [_]} = Features.prepare(config(%{url => %{}}), %{}, dst, opts)
      assert File.read!(Path.join(dst, "hello_0/install.sh")) == String.duplicate("x", 5000)
    end

    test "refuses an archive that's cut short", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      whole =
        FakeRegistry.tar(%{"devcontainer-feature.json" => ~s({"id":"hello"})}, [:compressed])

      archive = binary_part(whole, 0, byte_size(whole) - 8)
      opts = Keyword.put(opts, :fetch_url, fn ^url, _headers -> {:ok, archive} end)

      assert Features.prepare(config(%{url => %{}}), %{}, dst, opts) ==
               {:error, "couldn't unpack the feature #{url}: it isn't a whole gzipped archive"}
    end

    # A sparse file says how big it is without holding that much, and the
    # unpacker's own size limit can be talked out of counting it (an
    # extended header that restates its size). Features don't have them,
    # so an archive with one is refused before the unpacker reads it:
    # wherever the header sits, and however its checksum is written.
    test "refuses an archive with a sparse file in it", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"
      feature = FakeRegistry.tar(%{"devcontainer-feature.json" => ~s({"id":"hello"})})
      sparse = sparse_header("./big", 64 * 1024 * 1024 * 1024)

      archives = [
        sparse <> feature,
        # A folder whose size field isn't zero: readers disagree on where the next member is.
        tar_header("./dir/", 1024, ?5) <> sparse <> feature,
        # An extended header that says the next member is one byte long.
        pax_header("size", "1") <> sparse <> feature,
        # The checksum summed with bytes as signed, which unpackers also take.
        sparse_header("./big", 1024, :signed) <> feature,
        # And written with its padding in odd places.
        sparse_header("./big", 1024, :spaced) <> feature
      ]

      for archive <- archives do
        opts = Keyword.put(opts, :fetch_url, fn ^url, _headers -> {:ok, :zlib.gzip(archive)} end)

        assert Features.prepare(config(%{url => %{}}), %{}, dst, opts) ==
                 {:error,
                  "couldn't unpack the feature #{url}: it has a sparse file, which Foreman doesn't unpack"}

        refute File.exists?(Path.join(dst, "hello_0"))
      end
    end

    # What the scan takes for a sparse file's header is what erl_tar takes
    # for one: each of these lists as a member.
    test "the headers it refuses are ones the unpacker reads" do
      for header <- [
            sparse_header("./big", 1024),
            sparse_header("./big", 1024, :signed),
            sparse_header("./big", 1024, :spaced)
          ] do
        assert {:ok, [_member]} = :erl_tar.table({:binary, header <> <<0::size(8192)>>})
      end
    end

    test "a feature can carry an archive of its own", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"
      inner = FakeRegistry.tar(%{"a" => String.duplicate("S", 4096)})

      archive =
        FakeRegistry.tar(%{
          "devcontainer-feature.json" => ~s({"id":"hello"}),
          "payload.tar" => inner,
          "text" => String.duplicate("S", 100_000)
        })

      opts = Keyword.put(opts, :fetch_url, fn ^url, _headers -> {:ok, :zlib.gzip(archive)} end)

      assert {:ok, [_]} = Features.prepare(config(%{url => %{}}), %{}, dst, opts)
      assert File.read!(Path.join(dst, "hello_0/payload.tar")) == inner
    end

    # The devcontainer CLI packages features as plain tar under a .tgz name.
    test "unpacks an archive that isn't gzipped at all", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      archive =
        FakeRegistry.tar(%{
          "devcontainer-feature.json" => ~s({"id":"hello"}),
          "install.sh" => "x",
          ".hidden" => "y"
        })

      opts = Keyword.put(opts, :fetch_url, fn ^url, _headers -> {:ok, archive} end)

      assert {:ok, [_]} = Features.prepare(config(%{url => %{}}), %{}, dst, opts)
      assert File.read!(Path.join(dst, "hello_0/install.sh")) == "x"
      refute File.exists?(Path.join(dst, "hello_0/.hidden"))
    end

    test "won't unpack more than its limit, however the archive is framed", %{
      dst: dst,
      opts: opts
    } do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      archive =
        FakeRegistry.tar(%{
          "devcontainer-feature.json" => ~s({"id":"hello"}),
          "big" => String.duplicate("x", 300_000)
        })

      opts =
        opts
        |> Keyword.put(:fetch_url, fn ^url, _headers -> {:ok, archive} end)
        |> Keyword.put(:max_unpacked_bytes, 100_000)

      assert {:error, "couldn't unpack the feature " <> _} =
               Features.prepare(config(%{url => %{}}), %{}, dst, opts)
    end

    test "a download that finishes after the time is up doesn't count", %{dst: dst, opts: opts} do
      url = "https://example.com/devcontainer-feature-hello.tgz"

      archive =
        FakeRegistry.tar(%{"devcontainer-feature.json" => ~s({"id":"hello"})}, [:compressed])

      opts =
        opts
        |> Keyword.put(:deadline, System.monotonic_time(:millisecond) + 150)
        |> Keyword.put(:fetch_url, fn ^url, _headers ->
          Process.sleep(300)
          {:ok, archive}
        end)

      assert Features.prepare(config(%{url => %{}}), %{}, dst, opts) ==
               {:error, "there was no time left to get the feature #{url}"}
    end

    test "wants the archive named for its feature", %{dst: dst, opts: opts} do
      assert Features.prepare(config(%{"https://example.com/feature.tgz" => %{}}), %{}, dst, opts) ==
               {:error,
                "the feature https://example.com/feature.tgz has to be an archive named devcontainer-feature-<id>.tgz"}
    end
  end

  describe "lockfile/1" do
    test "records where each of the config's features came from", %{dst: dst, opts: opts} do
      registry = FakeRegistry.start()
      base = "#{registry.host}/org/features/base"

      base_digest =
        FakeRegistry.put_feature(registry, "org/features/base", "latest", %{
          "id" => "base",
          "version" => "1.0.0"
        })

      app_digest =
        FakeRegistry.put_feature(registry, "org/features/app", "1", %{
          "id" => "app",
          "version" => "2.0.0",
          "dependsOn" => %{base => %{}}
        })

      user_dep = "#{registry.host}/org/features/user-dep:1"

      FakeRegistry.put_feature(registry, "org/features/user-dep", "1", %{
        "id" => "user-dep",
        "version" => "1.0.0"
      })

      FakeRegistry.put_feature(registry, "org/features/extra", "1", %{
        "id" => "extra",
        "version" => "0.1.0",
        "dependsOn" => %{user_dep => %{}, base => %{}}
      })

      app = "#{registry.host}/org/features/app:1"
      extra = "#{registry.host}/org/features/extra:1"
      config = config(%{app => %{}, "./second" => %{}})
      additional = %{extra => %{}}

      {:ok, sets} = Features.prepare(config, additional, dst, opts)

      # Not the additional feature, and not the local one.
      assert Features.lockfile(sets) == """
             {
               "features": {
                 "#{app}": {
                   "version": "2.0.0",
                   "resolved": "#{registry.host}/org/features/app@#{app_digest}",
                   "integrity": "#{app_digest}",
                   "dependsOn": [
                     "#{base}"
                   ]
                 },
                 "#{base}": {
                   "version": "1.0.0",
                   "resolved": "#{registry.host}/org/features/base@#{base_digest}",
                   "integrity": "#{base_digest}"
                 }
               }
             }
             """
    end

    test "is an empty list of features when none come from a registry", %{dst: dst, opts: opts} do
      config = config(%{"./second" => %{}})
      {:ok, sets} = Features.prepare(config, %{}, dst, opts)

      assert Features.lockfile(sets) == "{\n  \"features\": {}\n}\n"
    end
  end

  # A tar header with a checksum that's right, as a reader would take it.
  defp tar_header(name, size, type) do
    octal = fn number, width ->
      number |> Integer.to_string(8) |> String.pad_leading(width - 1, "0") |> Kernel.<>(<<0>>)
    end

    fields = [
      String.pad_trailing(name, 100, <<0>>),
      octal.(0o644, 8),
      octal.(0, 8),
      octal.(0, 8),
      octal.(size, 12),
      octal.(0, 12),
      "        ",
      <<type>>,
      String.duplicate(<<0>>, 100),
      "ustar\0",
      "00"
    ]

    header = String.pad_trailing(IO.iodata_to_binary(fields), 512, <<0>>)
    sum = header |> :binary.bin_to_list() |> Enum.sum()
    checksum = (sum |> Integer.to_string(8) |> String.pad_leading(6, "0")) <> <<0, ?\s>>
    binary_part(header, 0, 148) <> checksum <> binary_part(header, 156, 356)
  end

  # GNU's header for a sparse file that says it's `real_size` bytes long
  # and holds none of them.
  defp sparse_header(name, real_size, checksum \\ :unsigned) do
    octal = fn number, width ->
      number |> Integer.to_string(8) |> String.pad_leading(width - 1, "0") |> Kernel.<>(<<0>>)
    end

    fields = [
      String.pad_trailing(name, 100, <<0>>),
      octal.(0o644, 8),
      octal.(0, 8),
      octal.(0, 8),
      octal.(0, 12),
      octal.(0, 12),
      "        ",
      "S",
      String.duplicate(<<0>>, 100),
      "ustar  \0"
    ]

    header = String.pad_trailing(IO.iodata_to_binary(fields), 483, <<0>>) <> octal.(real_size, 12)
    # A byte past 127, in the padding, is what makes the two sums differ.
    filler = if checksum == :signed, do: <<0xE9>>, else: <<0>>
    header = String.pad_trailing(header, 500, <<0>>) <> filler <> String.duplicate(<<0>>, 11)
    bytes = :binary.bin_to_list(header)

    field =
      case checksum do
        :unsigned ->
          (bytes |> Enum.sum() |> Integer.to_string(8) |> String.pad_leading(6, "0")) <>
            <<0, ?\s>>

        :signed ->
          (bytes
           |> Enum.map(&if(&1 > 127, do: &1 - 256, else: &1))
           |> Enum.sum()
           |> Integer.to_string(8)
           |> String.pad_leading(6, "0")) <> <<0, ?\s>>

        :spaced ->
          " " <>
            (bytes |> Enum.sum() |> Integer.to_string(8) |> String.pad_leading(5, " ")) <>
            <<0, ?\s>>
      end

    binary_part(header, 0, 148) <> field <> binary_part(header, 156, 356)
  end

  # An extended header with one record, for the member after it.
  defp pax_header(key, value) do
    body = "#{key}=#{value}\n"
    # A record starts with its own length, digits included.
    length = Enum.find(1..999, fn n -> byte_size("#{n} " <> body) == n end)
    record = "#{length} " <> body
    tar_header("./PaxHeaders/x", byte_size(record), ?x) <> String.pad_trailing(record, 512, <<0>>)
  end
end
