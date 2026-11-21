defmodule ForemanAgent.Devcontainer.ComposeTest do
  # The expected files are what the devcontainer CLI wrote for the same
  # project (test/fixtures/devcontainer/oracle).
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Compose

  @oracle Path.expand("../../fixtures/devcontainer/oracle/generated", __DIR__)
  @id "00p43hv7kvpt6ukvcaq9p4nibjrirlta6qtdfgfqdrjplstb733g"

  @build %{
    target: "dev_containers_target_stage",
    args: [
      {"_DEV_CONTAINERS_BASE_IMAGE", "dev_container_auto_added_stage_label"},
      {"_DEV_CONTAINERS_IMAGE_USER", "root"},
      {"_DEV_CONTAINERS_FEATURE_CONTENT_SOURCE", "dev_container_feature_content_temp"}
    ],
    contexts: [{"dev_containers_feature_content_source", "{{BUILD}}"}]
  }

  describe "build_override/1" do
    test "points a service that builds at the Dockerfile with the features" do
      assert Compose.build_override(%{
               version_prefix: "",
               service: "app",
               dockerfile: "{{BUILD}}/Dockerfile-with-features",
               build: @build,
               service_build: %{
                 context: "/repo/.devcontainer",
                 dockerfile_path: "Dockerfile",
                 target: nil,
                 args: %{}
               },
               image: nil,
               empty_context: "/meta/empty"
             }) == File.read!(Path.join(@oracle, "build.yml"))
    end

    test "replaces a target, and keeps the compose file's version" do
      yaml =
        Compose.build_override(%{
          version_prefix: "version: '3.8'\n\n",
          service: "app",
          dockerfile: "/b/Dockerfile-with-features",
          build: @build,
          service_build: %{
            context: "/repo",
            dockerfile_path: "Dockerfile",
            target: "dev",
            args: %{}
          },
          image: nil,
          empty_context: "/meta/empty"
        })

      assert String.starts_with?(
               yaml,
               "version: '3.8'\n\nservices:\n  app:\n    build:\n      dockerfile: /b/Dockerfile-with-features\n      target: dev_containers_target_stage\n      args:\n"
             )
    end

    test "quotes a service name YAML wouldn't read as text" do
      yaml =
        Compose.build_override(%{
          version_prefix: "",
          service: "123",
          dockerfile: "/b/Dockerfile-with-features",
          build: @build,
          service_build: %{
            context: "/repo",
            dockerfile_path: "Dockerfile",
            target: nil,
            args: %{}
          },
          image: nil,
          empty_context: "/meta/empty"
        })

      assert String.starts_with?(yaml, ~s(services:\n  "123":\n    build:\n))
    end

    test "gives a service that only names an image a build, an image name and an empty context" do
      assert Compose.build_override(%{
               version_prefix: "",
               service: "app",
               dockerfile: "/b/Dockerfile-with-features",
               build: %{@build | contexts: []},
               service_build: nil,
               image: "vsc-proj-abc",
               empty_context: "/meta/empty"
             }) == """
             services:
               app:
                 image: vsc-proj-abc
                 build:
                   dockerfile: /b/Dockerfile-with-features
                   context: /meta/empty
                   args:
                     - BUILDKIT_INLINE_CACHE=1
                     - _DEV_CONTAINERS_BASE_IMAGE=dev_container_auto_added_stage_label
                     - _DEV_CONTAINERS_IMAGE_USER=root
                     - _DEV_CONTAINERS_FEATURE_CONTENT_SOURCE=dev_container_feature_content_temp

             """
    end
  end

  describe "start_override/1" do
    @start %{
      version_prefix: "",
      service: "app",
      image: nil,
      entrypoints: ["/usr/local/share/local-entry.sh"],
      user_entrypoint: [],
      command: :keep,
      init: true,
      user: nil,
      env: %{"FROM_CONFIG" => ~s(a $b "c"), "ID" => @id},
      privileged: false,
      cap_add: ["SYS_PTRACE"],
      security_opt: ["seccomp=unconfined"],
      labels: ["oracle=1"],
      mounts: [
        %{"type" => "volume", "source" => "feature-vol-#{@id}", "target" => "/feature-vol"},
        "type=volume,source=oracle-data,target=/data"
      ]
    }

    test "runs the container the way the merged config says" do
      assert Compose.start_override(@start) == File.read!(Path.join(@oracle, "start.yml"))
    end

    test "with nothing to add, still wraps the entrypoint" do
      assert Compose.start_override(%{
               @start
               | entrypoints: [],
                 init: false,
                 env: %{},
                 cap_add: [],
                 security_opt: [],
                 labels: [],
                 mounts: []
             }) ==
               """
               services:
                 'app':
                   entrypoint: ["/bin/sh", "-c", "echo Container started\\n
               trap \\"exit 0\\" 15\\n
               \\n
               exec \\"$$@\\"\\n
               while sleep 1 & wait $$!; do :; done", "-"]
               """
    end

    test "writes the image, the user's entrypoint and command, a user and privileged" do
      yaml =
        Compose.start_override(%{
          @start
          | image: "vsc-proj-abc-uid",
            entrypoints: ["/a.sh", "/b.sh"],
            user_entrypoint: ["/docker-entrypoint.sh", "--x=$$HOME"],
            command: ["sleep", "infinity"],
            init: false,
            user: "vscode",
            privileged: true,
            env: %{"MULTI" => "a\nb", "QUOTE" => "it's"},
            cap_add: [],
            security_opt: [],
            labels: ["foreman.env_id=1", "devcontainer.metadata=[{\"x\":\"$y it's\"}]"],
            mounts: [
              "type=bind,source=/host,target=/in",
              "type=volume,target=/anon",
              %{"type" => "volume", "source" => "ext", "target" => "/ext", "external" => true}
            ]
        })

      assert yaml == """
             services:
               'app':
                 image: vsc-proj-abc-uid
                 entrypoint: ["/bin/sh", "-c", "echo Container started\\n
             trap \\"exit 0\\" 15\\n
             /a.sh\\n
             /b.sh\\n
             exec \\"$$@\\"\\n
             while sleep 1 & wait $$!; do :; done", "-", "/docker-entrypoint.sh", "--x=$$HOME"]
                 command: ["sleep","infinity"]
                 user: vscode
                 environment:
                   - 'MULTI=a\\nb'
                   - 'QUOTE=it''s'
                 privileged: true
                 labels:
                   - 'foreman.env_id=1'
                   - 'devcontainer.metadata=[{"x":"$$y it''s"}]'
                 volumes:
                   - /host:/in
                   - /anon
                   - ext:/ext
             volumes:
               
               ext:
                 external: true
             """
    end
  end

  describe "start_override/1 with values YAML would read differently" do
    test "quotes a mount, user or option that isn't plain" do
      yaml =
        Compose.start_override(%{
          @start
          | entrypoints: [],
            init: false,
            env: %{},
            labels: [],
            user: "1000:1000 # me",
            cap_add: ["SYS_PTRACE", "NET: ADMIN"],
            security_opt: ["label=disable", "- odd"],
            mounts: [
              "type=bind,source=/host/a,target=/srv/team #1",
              "type=bind,source=/plain,target=/plain",
              "type=volume,target=*star"
            ]
        })

      assert yaml =~ ~s(    user: "1000:1000 # me"\n)
      assert yaml =~ ~s(      - SYS_PTRACE\n      - "NET: ADMIN"\n)
      assert yaml =~ ~s(      - label=disable\n      - "- odd"\n)
      assert yaml =~ ~s(      - "/host/a:/srv/team #1"\n      - /plain:/plain\n      - "*star"\n)
    end
  end

  describe "start_override/1 with values YAML wouldn't read as text" do
    test "quotes what looks like a number, a boolean or nothing, and a tab before a comment" do
      yaml =
        Compose.start_override(%{
          @start
          | entrypoints: [],
            init: false,
            env: %{},
            labels: [],
            user: "1000",
            cap_add: ["true", "0x10", "ALL", "0b101", "a\rb"],
            security_opt: ["null", "1e3", "~"],
            mounts: [
              "type=volume,source=01000,target=/data",
              "type=bind,source=/a,target=/b\t#1"
            ]
        })

      assert yaml =~ ~s(    user: "1000"\n)

      assert yaml =~
               ~s(      - "true"\n      - "0x10"\n      - ALL\n      - "0b101"\n      - "a\\rb"\n)

      assert yaml =~ ~s(      - "null"\n      - "1e3"\n      - "~"\n)
      assert yaml =~ ~s(      - 01000:/data\n      - "/a:/b\\t#1"\n)
      assert yaml =~ ~s(volumes:\n  \n  "01000":\n)
    end

    test "keeps a feature's entrypoint whole when it has quotes or backslashes in it" do
      yaml =
        Compose.start_override(%{
          @start
          | entrypoints: [~S("/opt/my tool/start" --flag\x)],
            env: %{},
            labels: [],
            mounts: []
        })

      assert yaml =~
               ~S(trap \"exit 0\" 15\n) <> "\n" <> ~S(\"/opt/my tool/start\" --flag\\x\n) <> "\n"
    end
  end

  describe "user_commands/3" do
    @image %{"Entrypoint" => ["/entry.sh", "$HOME"], "Cmd" => ["run", "$1"]}

    test "keeps the service's own entrypoint and command" do
      assert Compose.user_commands(%{"entrypoint" => ["/x"], "command" => ["y"]}, @image, nil) ==
               {["/x"], :keep}

      assert Compose.user_commands(%{"command" => ["y"]}, @image, false) ==
               {["/entry.sh", "$$HOME"], :keep}
    end

    test "falls back to the image's, with dollars escaped for compose" do
      assert Compose.user_commands(%{}, @image, nil) == {["/entry.sh", "$$HOME"], ["run", "$$1"]}
      assert Compose.user_commands(%{}, %{"Entrypoint" => nil, "Cmd" => nil}, nil) == {[], []}
    end

    test "a service's entrypoint drops the image's command" do
      assert Compose.user_commands(%{"entrypoint" => ["/x"]}, @image, nil) == {["/x"], []}
    end

    test "overrideCommand runs neither" do
      assert Compose.user_commands(%{"entrypoint" => ["/x"], "command" => ["y"]}, @image, true) ==
               {[], []}
    end

    test "splits an entrypoint or command written as one string" do
      assert Compose.user_commands(
               %{"entrypoint" => "sh -c 'echo hi'", "command" => "a b"},
               @image,
               nil
             ) ==
               {["sh", "-c", "echo hi"], :keep}
    end
  end

  describe "service_build/2" do
    test "is nothing for a service that only names an image" do
      assert Compose.service_build(%{"image" => "debian"}, [
               "/repo/.devcontainer/docker-compose.yml"
             ]) == nil
    end

    test "reads a build as compose resolves it" do
      assert Compose.service_build(
               %{
                 "build" => %{
                   "context" => "/repo",
                   "dockerfile" => "docker/Dockerfile",
                   "target" => "dev",
                   "args" => %{"A" => "1"}
                 }
               },
               ["/repo/docker-compose.yml"]
             ) == %{
               context: "/repo",
               dockerfile_path: "/repo/docker/Dockerfile",
               target: "dev",
               args: %{"A" => "1"}
             }

      assert Compose.service_build(
               %{"build" => %{"context" => "/repo", "dockerfile" => "/abs/Dockerfile"}},
               []
             ) ==
               %{context: "/repo", dockerfile_path: "/abs/Dockerfile", target: nil, args: %{}}
    end

    test "fills in what a build leaves out" do
      assert Compose.service_build(%{"build" => "/repo/app"}, ["/repo/docker-compose.yml"]) ==
               %{
                 context: "/repo/app",
                 dockerfile_path: "/repo/app/Dockerfile",
                 target: nil,
                 args: %{}
               }

      assert Compose.service_build(%{"build" => %{}}, ["/repo/.devcontainer/docker-compose.yml"]) ==
               %{
                 context: "/repo/.devcontainer",
                 dockerfile_path: "/repo/.devcontainer/Dockerfile",
                 target: nil,
                 args: %{}
               }
    end

    test "build arguments given as a list" do
      assert %{args: %{"A" => "1", "B" => ""}} =
               Compose.service_build(
                 %{"build" => %{"context" => "/r", "args" => ["A=1", "B"]}},
                 []
               )
    end
  end

  describe "version_prefix/1" do
    test "is the compose file's version line, if it has one" do
      assert Compose.version_prefix("# c\nversion: \"3.8\"\nservices: {}\n") ==
               "version: \"3.8\"\n\n"

      assert Compose.version_prefix("services: {}\n") == ""
    end
  end

  describe "project_name/1" do
    test "is the name as compose takes it" do
      assert Compose.project_name("Storefront-2") == "storefront-2"
      assert Compose.project_name("My App_1!") == "myapp_1"
    end
  end
end
