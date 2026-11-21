defmodule ForemanAgent.Devcontainer.DockerfileTest do
  # The cases are the devcontainer CLI's own (dockerfileUtils.test.ts).
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Dockerfile

  describe "ensure_final_stage_name/2" do
    test "returns the last stage's name when it has one" do
      dockerfile = """

      FROM ubuntu:latest as base

      RUN some command

      FROM base as final

      COPY src dest
      RUN another command
      """

      assert Dockerfile.ensure_final_stage_name(dockerfile, "placeholder") == {:ok, "final", nil}
    end

    test "finds the name on an indented line with a platform and a comment" do
      dockerfile =
        "\nFROM ubuntu:latest as base\n\nRUN some command\n\n" <>
          " \tFROM  --platform=my-platform \tbase  as\t  final  #<- deliberately mixing: as something here\n\n" <>
          "COPY src dest\n"

      assert Dockerfile.ensure_final_stage_name(dockerfile, "placeholder") == {:ok, "final", nil}
    end

    test "names a last stage that has none" do
      dockerfile =
        "\nFROM ubuntu:latest as base\n\nRUN some command\n\nFROM base\n\nCOPY src dest\nRUN another command\n"

      assert Dockerfile.ensure_final_stage_name(dockerfile, "placeholder") ==
               {:ok, "placeholder",
                "\nFROM ubuntu:latest as base\n\nRUN some command\n\nFROM base AS placeholder\n\nCOPY src dest\nRUN another command\n"}
    end

    test "names a trailing FROM line" do
      dockerfile = "\nFROM ubuntu:latest as base\n\nRUN some command\n\nFROM base"

      assert Dockerfile.ensure_final_stage_name(dockerfile, "placeholder") ==
               {:ok, "placeholder", dockerfile <> " AS placeholder"}
    end

    test "puts the name before a comment, after the platform and image" do
      dockerfile =
        "\nFROM ubuntu:latest as base\n\n \tFROM  --platform=my-platform \tbase   #<- including: as something here\n\nCOPY src dest\n"

      assert Dockerfile.ensure_final_stage_name(dockerfile, "placeholder") ==
               {:ok, "placeholder",
                "\nFROM ubuntu:latest as base\n\n \tFROM  --platform=my-platform \tbase AS placeholder   #<- including: as something here\n\nCOPY src dest\n"}
    end

    test "a Dockerfile with no FROM is an error" do
      assert Dockerfile.ensure_final_stage_name("RUN echo hi\n", "placeholder") ==
               {:error, "the Dockerfile has no FROM instruction"}
    end
  end

  describe "find_base_image/4" do
    test "a simple FROM" do
      assert base_image("FROM image1\nUSER user1\n") == "image1"
    end

    test "FROM an ARG, which a build arg overrides" do
      dockerfile =
        "ARG BASE_IMAGE=\"image2\"\nFROM ${BASE_IMAGE}\nARG IMAGE_USER=user2\nUSER $IMAGE_USER\n"

      assert base_image(dockerfile) == "image2"
      assert base_image(dockerfile, %{"BASE_IMAGE" => "image3"}) == "image3"
    end

    test "follows stages from the target" do
      dockerfile =
        "\nFROM image1 as stage1\nFROM stage3 as stage2\nFROM image3 as stage3\nFROM image4 as stage4\n"

      assert base_image(dockerfile, %{}, "stage2") == "image3"
      assert base_image(dockerfile) == "image4"
    end

    test "a quoted image" do
      dockerfile =
        Dockerfile.parse(~s(\nARG BASE_IMAGE="ubuntu:latest"\nFROM "${BASE_IMAGE}"\n))

      assert length(dockerfile.stages) == 1
      assert Dockerfile.find_base_image(dockerfile, %{}, nil) == "ubuntu:latest"
    end

    test "variable expressions" do
      positive = "\nARG cloud\nFROM ${cloud:+mcr.microsoft.com/}azure-cli:latest\n"
      negative = "\nARG cloud\nFROM ${cloud:-mcr.microsoft.com/}azure-cli:latest\n"

      assert base_image(positive, %{"cloud" => "true"}) == "mcr.microsoft.com/azure-cli:latest"
      assert base_image(positive) == "azure-cli:latest"
      assert base_image(negative, %{"cloud" => "ghcr.io/"}) == "ghcr.io/azure-cli:latest"
      assert base_image(negative) == "mcr.microsoft.com/azure-cli:latest"
    end

    test "the platform arguments BuildKit sets" do
      dockerfile = "FROM --platform=$BUILDPLATFORM base-${TARGETARCH}\n"

      assert dockerfile
             |> Dockerfile.parse()
             |> Dockerfile.find_base_image(%{}, nil, %{"TARGETARCH" => "arm64"}) ==
               "base-arm64"
    end

    test "stages that name each other have no base image" do
      assert base_image("FROM b as a\nFROM a as b\n") == nil
    end
  end

  describe "find_user/5" do
    test "a simple USER" do
      assert user("FROM debian\nUSER user1\n") == "user1"
    end

    test "USER from an ARG, which a build arg overrides" do
      dockerfile = "FROM debian\nARG IMAGE_USER=user2\nUSER $IMAGE_USER\n"

      assert user(dockerfile) == "user2"
      assert user(dockerfile, %{"IMAGE_USER" => "user3"}) == "user3"
    end

    test "the last USER of the stage the target builds on" do
      dockerfile = """

      FROM image1 as stage1
      USER user1
      FROM stage3 as stage2
      FROM image3 as stage3
      USER user3_1
      USER user3_2
      FROM image4 as stage4
      USER user4
      """

      assert user(dockerfile, %{}, %{}, "stage2") == "user3_2"
    end

    test "ARG and ENV of the same name" do
      assert user("\nFROM debian\nENV USERNAME=user1\nARG USERNAME=user2\nUSER ${USERNAME}\n") ==
               "user2"

      assert user("\nFROM debian\nARG USERNAME=user1\nENV USERNAME=user2\nUSER ${USERNAME}\n") ==
               "user2"

      assert user("\nFROM debian\nENV USERNAME=user1\nARG USERNAME\nUSER ${USERNAME}\n") ==
               "user1"
    end

    test "an ARG doesn't carry into the next stage, an ENV does" do
      dockerfile =
        "\nFROM debian as one\nENV USERNAME=user1\nARG USERNAME=user2\nFROM one as two\nUSER ${USERNAME}\n"

      assert user(dockerfile) == "user1"
    end

    test "an ARG before the first FROM" do
      assert user("\nARG USERNAME=user1\nFROM debian\nUSER ${USERNAME}\n") == "user1"
    end

    test "a variable nothing sets" do
      assert user("\nFROM debian\nUSER ${USERNAME}\n") == nil
    end

    test "an ENV set from an ARG, and several variables" do
      assert user(
               "\nFROM debian\nARG USERNAME1=user1\nENV USERNAME2=${USERNAME1}\nUSER ${USERNAME2}\n"
             ) == "user1"

      assert user(
               "\nFROM debian\nARG USERNAME1=user1\nENV USERNAME2=user2\nUSER A${USERNAME1}A${USERNAME2}A\n"
             ) ==
               "Auser1Auser2A"
    end

    test "an ENV of the base image" do
      assert user("\nFROM mybase\nUSER ${USERNAME}\n", %{}, %{"USERNAME" => "user1"}) == "user1"
    end

    test "no USER at all" do
      assert user("FROM debian\nRUN true\n") == nil
    end
  end

  describe "supports_build_contexts/1" do
    test "without a syntax directive, or with someone else's" do
      assert supports("FROM debian") == false
      assert supports("# syntax=mycompany/myimage:1.4\nFROM debian") == :unknown
    end

    test "by the version of docker/dockerfile" do
      assert supports("# syntax=docker/dockerfile:1.4\nFROM debian") == true

      for prerelease <- ["", "-labs"],
          {version, expected} <- [
            {"0", false},
            {"1", true},
            {"1.2", false},
            {"1.2.3", false},
            {"1.4", true},
            {"1.4.5", true},
            {"1.5", true},
            {"1.5.0", true},
            {"2", true},
            {"", true},
            {"latest", true}
          ] do
        tag = version <> prerelease
        suffix = if tag == "", do: "", else: ":" <> tag
        dockerfile = "# syntax=docker.io/docker/dockerfile#{suffix}\n        FROM debian"

        assert supports(dockerfile) == expected, "docker/dockerfile#{suffix}"
      end
    end
  end

  describe "parse/1" do
    test "ENV with an equals sign, with spaces around it, and without one" do
      for line <- ["ENV A=B", "ENV A = B", "ENV A B"] do
        assert %{stages: [%{instructions: [%{instruction: "ENV", name: "A", value: "B"}]}]} =
                 Dockerfile.parse("FROM debian\n" <> line)
      end
    end

    test "lowercase instructions" do
      assert %{
               stages: [
                 %{
                   from: %{image: "E"},
                   instructions: [
                     %{instruction: "ENV", name: "A", value: "B"},
                     %{instruction: "ARG", name: "C", value: nil},
                     %{instruction: "USER", name: "D"}
                   ]
                 }
               ]
             } = Dockerfile.parse("from E\nenv A=B\narg C\nuser D\n")
    end

    test "the syntax directive, which only the first lines can hold" do
      assert Dockerfile.parse("# syntax=docker/dockerfile:1.7\n# escape=`\nFROM debian").preamble.directives ==
               %{"syntax" => "docker/dockerfile:1.7", "escape" => "`"}

      assert Dockerfile.parse("\n# syntax=docker/dockerfile:1.7\nFROM debian").preamble.directives ==
               %{}
    end
  end

  defp base_image(text, args \\ %{}, target \\ nil),
    do: text |> Dockerfile.parse() |> Dockerfile.find_base_image(args, target)

  defp user(text, args \\ %{}, base_env \\ %{}, target \\ nil),
    do: text |> Dockerfile.parse() |> Dockerfile.find_user(args, base_env, %{}, target)

  defp supports(text), do: text |> Dockerfile.parse() |> Dockerfile.supports_build_contexts()
end
