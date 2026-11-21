defmodule ForemanAgent.Devcontainer.Features.BuildTest do
  # The expected files are what the devcontainer CLI wrote for the same
  # project (test/fixtures/devcontainer/oracle).
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.{Features, Metadata}
  alias ForemanAgent.Devcontainer.Features.{Build, Registry}

  @moduletag :tmp_dir

  @oracle Path.expand("../../../fixtures/devcontainer/oracle", __DIR__)
  @devcontainer_id "00p43hv7kvpt6ukvcaq9p4nibjrirlta6qtdfgfqdrjplstb733g"

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "proj")
    File.mkdir_p!(workspace)
    File.cp_r!(Path.join(@oracle, "project/devcontainer"), Path.join(workspace, ".devcontainer"))
    config_path = Path.join(workspace, ".devcontainer/devcontainer.json")
    {:ok, config} = ForemanProtocol.Jsonc.decode(File.read!(config_path))
    dst = Path.join(tmp, "build")

    {:ok, sets} =
      Features.prepare(config, %{}, dst,
        workspace: workspace,
        config_path: config_path,
        registry: Registry.new()
      )

    %{config: config, sets: sets, dst: dst}
  end

  defp generated(path), do: File.read!(Path.join([@oracle, "generated", path]))

  describe "variables/1" do
    test "is the feature's options as shell variables: its defaults, then what the config set", %{
      sets: [second, local]
    } do
      assert Build.variables(local) == [~s(ZETA="z"), ~s(GREETING="hi there"), ~s(LOUD="true")]
      assert Build.variables(second) == []
    end

    test "a plain value is the feature's version option, when it has one" do
      set = fn value, options ->
        %{
          value: value,
          metadata: %{"options" => options},
          order: %{"options" => Map.keys(options)}
        }
      end

      assert Build.variables(set.("1.22", %{"version" => %{"default" => "latest"}})) == [
               ~s(VERSION="1.22")
             ]

      assert Build.variables(set.(true, %{"version" => %{"default" => "latest"}})) == [
               ~s(VERSION="true")
             ]

      assert Build.variables(set.("1.22", %{"other" => %{"default" => "x"}})) == [~s(OTHER="x")]
      assert Build.variables(set.(%{}, %{"noDefault" => %{"type" => "string"}})) == []
    end

    test "option names become variable names" do
      set = %{value: %{"my-opt.x" => 1, "9lives" => false}, metadata: %{}, order: %{}}

      assert Build.variables(set) == [~s(_LIVES="false"), ~s(MY_OPT_X="1")]
    end
  end

  describe "write_files/4" do
    test "writes each feature's variables and its install wrapper", %{sets: sets, dst: dst} do
      assert :ok = Build.write_files(sets, dst, "root", "dev")

      for file <- [
            "devcontainer-features.builtin.env",
            "second_0/devcontainer-features.env",
            "second_0/devcontainer-features-install.sh",
            "local-feature_1/devcontainer-features.env",
            "local-feature_1/devcontainer-features-install.sh"
          ] do
        assert File.read!(Path.join(dst, file)) == generated(file), file
      end
    end
  end

  describe "write_files/4 and what a feature brought with it" do
    test "replaces a link where a generated file goes, and never writes through it", %{
      sets: sets,
      dst: dst,
      tmp_dir: tmp
    } do
      outside = Path.join(tmp, "outside")
      File.write!(outside, "untouched")
      [second | _] = sets

      for name <- ["devcontainer-features.env", "devcontainer-features-install.sh"] do
        File.rm_rf!(Path.join(second.cache_path, name))
        File.ln_s!(outside, Path.join(second.cache_path, name))
      end

      File.rm_rf!(Path.join(dst, "devcontainer-features.builtin.env"))
      File.ln_s!(outside, Path.join(dst, "devcontainer-features.builtin.env"))

      assert :ok = Build.write_files(sets, dst, "root", "dev")

      assert File.read!(outside) == "untouched"

      for path <- [
            Path.join(second.cache_path, "devcontainer-features.env"),
            Path.join(second.cache_path, "devcontainer-features-install.sh"),
            Path.join(dst, "devcontainer-features.builtin.env")
          ] do
        assert %File.Stat{type: :regular} = File.lstat!(path)
      end
    end
  end

  describe "wrapper/2" do
    test "names a registry feature by its ref, and warns about one that's deprecated or renamed" do
      set = %{
        source: %{
          type: :oci,
          user_feature_id: "ghcr.io/o/f/old:1",
          user_feature_id_without_version: "ghcr.io/o/f/old"
        },
        id: "old",
        metadata: %{
          "id" => "old",
          "deprecated" => true,
          "legacyIds" => ["older"],
          "currentId" => "new"
        }
      }

      script = Build.wrapper(set, [])

      assert script =~ "echo 'Id            : ghcr.io/o/f/old'"
      assert script =~ "echo 'Feature       : Unknown'"

      assert script =~
               ~s|echo '(!) WARNING: Using the deprecated Feature "old". This Feature will no longer receive any further updates/support.\n| <>
                 ~s|(!) WARNING: This feature has been renamed. Please update the reference in devcontainer.json to "new".'|
    end
  end

  describe "dockerfile/2" do
    test "extends the service's own Dockerfile with the features", %{
      config: config,
      sets: sets,
      dst: dst
    } do
      # The config as the CLI had it once its variables were replaced.
      substituted = put_in(config, ["containerEnv", "ID"], @devcontainer_id)

      build =
        Build.dockerfile(sets,
          dst: dst,
          base_name: "dev_container_auto_added_stage_label",
          image_user: "root",
          container_user: "root",
          remote_user: "dev",
          metadata: Metadata.build([], sets, config),
          container_env: substituted["containerEnv"],
          container_env_order: ["FROM_CONFIG", "ID"],
          syntax: nil
        )

      user_dockerfile =
        "FROM debian:bookworm-slim AS dev_container_auto_added_stage_label\nRUN useradd -m -s /bin/bash dev\n"

      # The one difference from the CLI's: an object inside an entry has its
      # keys sorted, where the CLI keeps the order they were written in.
      expected =
        String.replace(
          generated("Dockerfile-with-features"),
          ~S|{\"type\":\"volume\",\"source\":\"feature-vol-\${devcontainerId}\",\"target\":\"/feature-vol\"}|,
          ~S|{\"source\":\"feature-vol-\${devcontainerId}\",\"target\":\"/feature-vol\",\"type\":\"volume\"}|
        )

      assert build.prefix <> user_dockerfile <> "\n" <> build.content == expected

      assert build.target == "dev_containers_target_stage"

      assert build.args == [
               {"_DEV_CONTAINERS_BASE_IMAGE", "dev_container_auto_added_stage_label"},
               {"_DEV_CONTAINERS_IMAGE_USER", "root"},
               {"_DEV_CONTAINERS_FEATURE_CONTENT_SOURCE", "dev_container_feature_content_temp"}
             ]

      assert build.contexts == [{"dev_containers_feature_content_source", dst}]
    end

    test "keeps the Dockerfile's own syntax directive", %{sets: sets, dst: dst} do
      build =
        Build.dockerfile(sets,
          dst: dst,
          base_name: "base",
          image_user: "root",
          container_user: "root",
          remote_user: "root",
          metadata: [],
          container_env: nil,
          syntax: "docker/dockerfile:1.7"
        )

      assert build.prefix ==
               "# syntax=docker/dockerfile:1.7\nARG _DEV_CONTAINERS_BASE_IMAGE=scratch\n"
    end
  end

  describe "label_only/2" do
    test "is a stage that only labels the image, when there are no features" do
      build = Build.label_only("base", [%{"remoteUser" => "dev"}], nil)

      assert build.prefix == "\nARG _DEV_CONTAINERS_BASE_IMAGE=scratch\n"

      assert build.content == ~S"""

             FROM $_DEV_CONTAINERS_BASE_IMAGE AS dev_containers_target_stage
             LABEL devcontainer.metadata="[ \
             {\"remoteUser\":\"dev\"} \
             ]"
             """

      assert build.args == [{"_DEV_CONTAINERS_BASE_IMAGE", "base"}]
      assert build.contexts == []
      assert build.target == "dev_containers_target_stage"
    end
  end

  describe "passwd_command/1" do
    test "looks a user up, however its name is spelled" do
      assert Build.passwd_command("dev") ==
               " (command -v getent >/dev/null 2>&1 && getent passwd 'dev' || grep -E '^dev|^[^:]*:[^:]*:dev:' /etc/passwd || true)"

      expected = ~S"""
       (command -v getent >/dev/null 2>&1 && getent passwd 'o\'brien.x' || grep -E '^o\'brien\.x|^[^:]*:[^:]*:o\'brien\.x:' /etc/passwd || true)
      """

      assert Build.passwd_command("o'brien.x") == String.trim_trailing(expected, "\n")
    end
  end
end
