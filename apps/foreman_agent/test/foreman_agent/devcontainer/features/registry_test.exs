defmodule ForemanAgent.Devcontainer.Features.RegistryTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Devcontainer.Features.{Ref, Registry}
  alias ForemanAgent.Test.FakeRegistry

  @metadata %{"id" => "hello", "version" => "1.2.3", "name" => "Hello"}

  defp ref!(registry, rest) do
    {:ok, ref} = Ref.parse("#{registry.host}/#{rest}")
    ref
  end

  defp client(auths \\ %{}, opts \\ []) do
    test_pid = self()

    Registry.new(
      [auths: auths, log: fn text -> send(test_pid, {:registry_log, text}) end] ++ opts
    )
  end

  defp credentials(registry, user, password),
    do: %{registry.host => %{"auth" => Base.encode64("#{user}:#{password}")}}

  defp paths(registry),
    do: registry |> FakeRegistry.requests() |> Enum.map(&{&1.path, &1.authorization})

  describe "manifest/3" do
    test "fetches a feature's manifest, with its digest" do
      registry = FakeRegistry.start()
      digest = FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert {:ok, %{digest: ^digest, manifest: manifest}} =
               Registry.manifest(client(), ref!(registry, "org/features/hello:1"))

      assert JSON.decode!(manifest["annotations"]["dev.containers.metadata"]) == @metadata
      assert [%{"digest" => "sha256:" <> _}] = manifest["layers"]
    end

    test "works out the digest when the registry doesn't send it" do
      registry = FakeRegistry.start(digest_header: false)
      digest = FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert {:ok, %{digest: ^digest}} =
               Registry.manifest(client(), ref!(registry, "org/features/hello:1"))
    end

    test "a feature the registry doesn't have isn't found" do
      registry = FakeRegistry.start()

      assert Registry.manifest(client(), ref!(registry, "org/features/nope:1")) ==
               {:error, :not_found}
    end

    test "asks for the digest it's given, and for a ref's own" do
      registry = FakeRegistry.start()
      digest = FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert {:ok, %{digest: ^digest}} =
               Registry.manifest(client(), ref!(registry, "org/features/hello:2"), digest)

      assert {:ok, %{digest: ^digest}} =
               Registry.manifest(client(), ref!(registry, "org/features/hello@#{digest}"))

      assert [{"/v2/org/features/hello/manifests/" <> ^digest, nil} | _] = paths(registry)
    end

    test "a manifest that isn't the one its digest names is refused" do
      registry = FakeRegistry.start()
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      other = FakeRegistry.put_feature(registry, "org/features/other", "1", %{"id" => "other"})

      # The registry answers the tag with something else.
      Agent.update(registry.state, fn state ->
        put_in(
          state,
          [:manifests, {"org/features/other", other}],
          state.manifests[{"org/features/hello", "1"}]
        )
      end)

      assert Registry.manifest(client(), ref!(registry, "org/features/other@#{other}")) ==
               {:error, "the digest of #{registry.host}/org/features/other doesn't match"}
    end

    test "an image isn't a feature" do
      registry = FakeRegistry.start()

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata, %{},
        config_media_type: "application/vnd.oci.image.config.v1+json"
      )

      assert Registry.manifest(client(), ref!(registry, "org/features/hello:1")) ==
               {:error, :not_found}
    end

    test "a name that isn't a host isn't asked for" do
      {:ok, ref} = Ref.parse("devcontainers/features/go")

      assert Registry.manifest(client(), ref) == {:error, :not_found}
    end
  end

  describe "authentication" do
    test "trades the registry's credentials for a token, and keeps it for the next request" do
      registry = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"})
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      client = client(credentials(registry, "nate", "s3cret"))
      ref = ref!(registry, "org/features/hello:1")
      basic = "Basic " <> Base.encode64("nate:s3cret")
      bearer = "Bearer tok-repository:org/features/hello:pull"

      assert {:ok, _} = Registry.manifest(client, ref)
      assert {:ok, _} = Registry.manifest(client, ref)

      assert paths(registry) == [
               {"/v2/org/features/hello/manifests/1", nil},
               {"/token", basic},
               {"/v2/org/features/hello/manifests/1", bearer},
               {"/v2/org/features/hello/manifests/1", bearer}
             ]

      assert %{
               query: %{
                 "service" => "registry.test",
                 "scope" => "repository:org/features/hello:pull"
               }
             } =
               Enum.at(FakeRegistry.requests(registry), 1)
    end

    test "asks for a token without credentials when it has none" do
      registry = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"}, anonymous: true)
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert {:ok, _} = Registry.manifest(client(), ref!(registry, "org/features/hello:1"))
      assert {"/token", nil} = Enum.at(paths(registry), 1)
    end

    test "tries again without credentials the token service turns down" do
      registry = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"}, anonymous: true)
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      client = client(credentials(registry, "nate", "expired"))

      assert {:ok, _} = Registry.manifest(client, ref!(registry, "org/features/hello:1"))

      assert [_, {"/token", "Basic " <> _}, {"/token", nil}, {_, "Bearer " <> _}] =
               paths(registry)
    end

    test "reads the token whichever name it comes under" do
      registry =
        FakeRegistry.start(
          auth: {:bearer, "nate", "s3cret"},
          anonymous: true,
          token_key: "access_token"
        )

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert {:ok, _} = Registry.manifest(client(), ref!(registry, "org/features/hello:1"))
    end

    test "trades an identity token as a refresh token" do
      registry = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"})
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      client = client(%{registry.host => %{"auth" => "", "identitytoken" => "refresh-me"}})

      assert {:error, _} = Registry.manifest(client, ref!(registry, "org/features/hello:1"))

      assert %{method: "POST", path: "/token", authorization: nil, body: body} =
               Enum.at(FakeRegistry.requests(registry), 1)

      assert URI.decode_query(body) == %{
               "client_id" => "devcontainer",
               "grant_type" => "refresh_token",
               "service" => "registry.test",
               "scope" => "repository:org/features/hello:pull",
               "refresh_token" => "refresh-me"
             }
    end

    test "fails without a token" do
      registry = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"})
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert Registry.manifest(client(), ref!(registry, "org/features/hello:1")) ==
               {:error, "couldn't authenticate with #{registry.host}"}
    end

    test "answers a basic challenge with the registry's credentials" do
      registry = FakeRegistry.start(auth: {:basic, "nate", "s3cret"})
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      client = client(credentials(registry, "nate", "s3cret"))

      assert {:ok, _} = Registry.manifest(client, ref!(registry, "org/features/hello:1"))
      assert {:error, _} = Registry.manifest(client(), ref!(registry, "org/features/hello:1"))
    end

    test "never asks another host for a token, with credentials or without" do
      other = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"}, anonymous: true)

      registry =
        FakeRegistry.start(
          auth: {:bearer, "nate", "s3cret"},
          realm: "http://127.0.0.1:#{other.port}/token"
        )

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      client = client(credentials(registry, "nate", "s3cret"))

      assert Registry.manifest(client, ref!(registry, "org/features/hello:1")) ==
               {:error, "couldn't authenticate with #{registry.host}"}

      assert FakeRegistry.requests(other) == []
      assert_received {:registry_log, "Registry " <> _ = text}
      assert text =~ "untrusted"
    end

    test "doesn't follow a token service's redirect" do
      other = FakeRegistry.start(auth: {:bearer, "nate", "s3cret"}, anonymous: true)

      registry =
        FakeRegistry.start(
          auth: {:bearer, "nate", "s3cret"},
          token_redirect: "http://127.0.0.1:#{other.port}/token"
        )

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)

      assert {:error, _} =
               Registry.manifest(
                 client(credentials(registry, "nate", "s3cret")),
                 ref!(registry, "org/features/hello:1")
               )

      assert FakeRegistry.requests(other) == []
    end
  end

  describe "auths/2" do
    @docker %{"registry.example.com" => %{"auth" => "ZG9ja2Vy"}}

    test "is the Docker config's, as it is, with nothing else to go on" do
      assert Registry.auths(@docker, %{}) == @docker
    end

    test "uses a GITHUB_TOKEN for ghcr.io, unless there's a credential for it already" do
      env = %{"GITHUB_TOKEN" => "ghp_x"}
      github = %{"auth" => Base.encode64("USERNAME:ghp_x")}

      assert Registry.auths(@docker, env) == Map.put(@docker, "ghcr.io", github)

      assert Registry.auths(%{"ghcr.io" => %{"auth" => "own"}}, env) == %{
               "ghcr.io" => %{"auth" => "own"}
             }

      assert Registry.auths(%{}, Map.put(env, "GITHUB_HOST", "github.com")) == %{
               "ghcr.io" => github
             }

      assert Registry.auths(%{}, Map.put(env, "GITHUB_HOST", "ghe.example.com")) == %{}
      assert Registry.auths(%{}, %{"GITHUB_TOKEN" => ""}) == %{}
    end

    test "takes DEVCONTAINERS_OCI_AUTH over both" do
      env = %{
        "DEVCONTAINERS_OCI_AUTH" => "ghcr.io|me|tok1,registry.example.com|you|tok2,broken",
        "GITHUB_TOKEN" => "ghp_x"
      }

      assert Registry.auths(@docker, env) == %{
               "ghcr.io" => %{"auth" => Base.encode64("me:tok1")},
               "registry.example.com" => %{"auth" => Base.encode64("you:tok2")}
             }
    end

    test "github_token/1 is the token for github.com, if there is one" do
      assert Registry.github_token(%{"GITHUB_TOKEN" => "ghp_x"}) == "ghp_x"

      assert Registry.github_token(%{
               "GITHUB_TOKEN" => "ghp_x",
               "GITHUB_HOST" => "ghe.example.com"
             }) == nil

      assert Registry.github_token(%{}) == nil
    end
  end

  describe "the deadline" do
    test "nothing is asked for once it has passed" do
      registry = FakeRegistry.start()
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      late = client(%{}, deadline: System.monotonic_time(:millisecond) - 1)

      assert Registry.manifest(late, ref!(registry, "org/features/hello:1")) ==
               {:error, "there was no time left to reach #{registry.host}"}

      assert FakeRegistry.requests(registry) == []
    end
  end

  describe "a registry that's slow" do
    test "isn't waited for past the deadline" do
      registry = FakeRegistry.start(delay: 2_000)
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      started = System.monotonic_time(:millisecond)
      client = client(%{}, deadline: started + 200)

      assert {:error, "couldn't reach " <> _} =
               Registry.manifest(client, ref!(registry, "org/features/hello:1"))

      assert System.monotonic_time(:millisecond) - started < 1_500
    end
  end

  describe "trusted_realm?/3" do
    test "the registry's own authority, over HTTPS" do
      assert Registry.trusted_realm?("https://ghcr.io/token", "https://ghcr.io", [])
      assert Registry.trusted_realm?("https://GHCR.io/token?x=1", "https://ghcr.io", [])
      refute Registry.trusted_realm?("http://ghcr.io/token", "https://ghcr.io", [])
      refute Registry.trusted_realm?("https://ghcr.io:8443/token", "https://ghcr.io", [])
      refute Registry.trusted_realm?("https://evil.example/token", "https://ghcr.io", [])
      refute Registry.trusted_realm?("not a url", "https://ghcr.io", [])
    end

    test "plain HTTP only on localhost" do
      assert Registry.trusted_realm?("http://localhost:5000/token", "http://localhost:5000", [])
      refute Registry.trusted_realm?("http://localhost:5001/token", "http://localhost:5000", [])
    end

    test "the token services Docker Hub and GitLab use" do
      assert Registry.trusted_realm?(
               "https://auth.docker.io/token",
               "https://registry-1.docker.io",
               []
             )

      assert Registry.trusted_realm?(
               "https://auth.docker.io/token",
               "https://index.docker.io",
               []
             )

      assert Registry.trusted_realm?(
               "https://gitlab.com/jwt/auth",
               "https://registry.gitlab.com",
               []
             )

      refute Registry.trusted_realm?("https://auth.docker.io/token", "https://ghcr.io", [])

      refute Registry.trusted_realm?(
               "http://auth.docker.io/token",
               "https://registry-1.docker.io",
               []
             )
    end

    test "a pairing the caller trusts" do
      allowed = ["registry.example.com=auth.example.com"]

      assert Registry.trusted_realm?(
               "https://auth.example.com/token",
               "https://registry.example.com",
               allowed
             )

      refute Registry.trusted_realm?(
               "https://auth.example.com/token",
               "https://other.example.com",
               allowed
             )
    end
  end

  describe "blob/3" do
    test "downloads a layer and checks it against its digest" do
      registry = FakeRegistry.start()
      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      ref = ref!(registry, "org/features/hello:1")
      {:ok, %{manifest: %{"layers" => [%{"digest" => layer}]}}} = Registry.manifest(client(), ref)

      assert {:ok, tar} = Registry.blob(client(), ref, layer)
      assert FakeRegistry.digest(tar) == layer
    end

    test "content that isn't what the digest names is refused" do
      registry = FakeRegistry.start()

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata, %{},
        layer: "tampered"
      )

      ref = ref!(registry, "org/features/hello:1")
      {:ok, %{manifest: %{"layers" => [%{"digest" => layer}]}}} = Registry.manifest(client(), ref)

      assert Registry.blob(client(), ref, layer) ==
               {:error, "the digest of #{registry.host}/org/features/hello doesn't match"}
    end

    test "follows a redirect to storage elsewhere, without the registry's token" do
      storage = FakeRegistry.start()

      registry =
        FakeRegistry.start(
          auth: {:bearer, "nate", "s3cret"},
          blob_redirect: "http://127.0.0.1:#{storage.port}"
        )

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata)
      Agent.update(storage.state, &%{&1 | blobs: Agent.get(registry.state, fn s -> s.blobs end)})

      client = client(credentials(registry, "nate", "s3cret"))
      ref = ref!(registry, "org/features/hello:1")
      {:ok, %{manifest: %{"layers" => [%{"digest" => layer}]}}} = Registry.manifest(client, ref)

      assert {:ok, _tar} = Registry.blob(client, ref, layer)

      assert [%{path: "/v2/org/features/hello/blobs/" <> _, authorization: nil}] =
               FakeRegistry.requests(storage)
    end

    test "gives up on a download past its size limit" do
      registry = FakeRegistry.start()

      FakeRegistry.put_feature(registry, "org/features/hello", "1", @metadata, %{
        "big" => String.duplicate("x", 200_000)
      })

      ref = ref!(registry, "org/features/hello:1")
      {:ok, %{manifest: %{"layers" => [%{"digest" => layer}]}}} = Registry.manifest(client(), ref)

      assert Registry.blob(client(%{}, max_blob_bytes: 100_000), ref, layer) ==
               {:error,
                "#{registry.host}/org/features/hello is larger than Foreman downloads (100000 bytes)"}
    end
  end
end
