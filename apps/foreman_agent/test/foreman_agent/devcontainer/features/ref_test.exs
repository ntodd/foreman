defmodule ForemanAgent.Devcontainer.Features.RefTest do
  # The cases are the devcontainer CLI's own (containerFeaturesOCI.test.ts).
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Features.Ref

  @digest "sha256:4ef08c9c3b708f3c2faecc5a898b39736423dd639f09f2a9f8bf9b0b9252ef0a"

  test "a ref with a tag" do
    assert {:ok, ref} = Ref.parse("ghcr.io/devcontainers/templates/docker-from-docker:latest")

    assert ref == %Ref{
             scheme: "https",
             registry: "ghcr.io",
             owner: "devcontainers",
             namespace: "devcontainers/templates",
             path: "devcontainers/templates/docker-from-docker",
             resource: "ghcr.io/devcontainers/templates/docker-from-docker",
             id: "docker-from-docker",
             version: "latest",
             tag: "latest",
             digest: nil
           }
  end

  test "a ref with a digest" do
    assert {:ok, ref} = Ref.parse("ghcr.io/my-org/my-features/my-feat@#{@digest}")

    assert %Ref{
             id: "my-feat",
             namespace: "my-org/my-features",
             tag: nil,
             digest: @digest,
             version: @digest
           } = ref

    assert ref.resource == "ghcr.io/my-org/my-features/my-feat"
  end

  test "a ref with a tag and a digest" do
    assert {:ok, ref} =
             Ref.parse("mcr.microsoft.com/devcontainers/go:2.3.1-1.27-bookworm@#{@digest}")

    assert %Ref{
             id: "go",
             namespace: "devcontainers",
             owner: "devcontainers",
             registry: "mcr.microsoft.com",
             resource: "mcr.microsoft.com/devcontainers/go",
             path: "devcontainers/go",
             tag: "2.3.1-1.27-bookworm",
             digest: @digest,
             version: @digest
           } = ref
  end

  test "a registry with a port" do
    assert {:ok, %Ref{registry: "docker.io:8001", tag: "1.3.4", digest: nil, version: "1.3.4"}} =
             Ref.parse("docker.io:8001/devcontainers/templates/docker-from-docker:1.3.4")

    assert {:ok,
            %Ref{registry: "docker.io:8001", tag: "1.3.4", digest: @digest, version: @digest}} =
             Ref.parse(
               "docker.io:8001/devcontainers/templates/docker-from-docker:1.3.4@#{@digest}"
             )

    assert {:ok, %Ref{registry: "docker.io:8001", tag: "latest", id: "docker-from-docker"}} =
             Ref.parse("docker.io:8001/devcontainers/templates/docker-from-docker")
  end

  test "no version is latest, and capitals are lowered" do
    assert {:ok,
            %Ref{
              id: "docker-from-docker",
              namespace: "devcontainers/templates",
              tag: "latest",
              version: "latest"
            }} =
             Ref.parse("ghcr.io/DeVContainERS/templates/Docker-FROM-Docker")
  end

  test "localhost is plain HTTP, with a port or without" do
    assert {:ok, %Ref{scheme: "http"}} = Ref.parse("localhost/org/features/x")

    assert {:ok, %Ref{scheme: "http", registry: "localhost:5000"}} =
             Ref.parse("localhost:5000/org/features/x:1")

    assert {:ok, %Ref{scheme: "https"}} = Ref.parse("localhost.example.com/org/features/x")
  end

  test "devcontainers-contrib is devcontainers-extra now" do
    assert {:ok,
            %Ref{owner: "devcontainers-extra", namespace: "devcontainers-extra/features"} = ref} =
             Ref.parse("ghcr.io/devcontainers-contrib/features/act:1")

    # The resource is what was asked for; the path is where it's fetched from.
    assert ref.resource == "ghcr.io/devcontainers-contrib/features/act"
    assert ref.path == "devcontainers-extra/features/act"
  end

  test "what isn't a ref" do
    assert Ref.parse("./local") == :error
    assert Ref.parse("ghcr.io/org/features/x:bad tag") == :error
    assert Ref.parse("ghcr.io/org/features/x@md5:abc") == :error
    assert Ref.parse("ghcr.io/org/features/x@sha256") == :error
    assert Ref.parse("ghcr.io/org//x") == :error
    assert Ref.parse("ghcr.io/org/features/-x") == :error
    assert Ref.parse("justaname") == :error
  end
end
