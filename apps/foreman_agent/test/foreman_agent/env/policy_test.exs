defmodule ForemanAgent.Env.PolicyTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Env.Policy

  @workspace "/srv/foreman/envs/e1/workspace"
  @secrets "/run/foreman/envs/e1"

  defp ctx(rules \\ %{}) do
    %{
      workspace_root: @workspace,
      secrets_dir: @secrets,
      protected: ["/run/foreman", "/var/lib/foreman-agent", "/srv/foreman/envs"],
      rules: Map.merge(Policy.default_rules(), rules)
    }
  end

  defp compose(services, extra \\ %{}) do
    Map.merge(%{"name" => "storefront-2", "services" => services}, extra)
  end

  defp bind(source, target), do: %{"type" => "bind", "source" => source, "target" => target}

  test "allows binds inside the workspace and the environment's own secrets mount" do
    config =
      compose(%{
        "app" => %{
          "volumes" => [
            bind(@workspace, "/workspaces"),
            bind(@workspace <> "/storefront/.cache", "/cache"),
            Map.put(bind(@secrets, "/run/foreman"), "read_only", true),
            %{"type" => "volume", "source" => "pgdata", "target" => "/var/lib/postgresql"}
          ]
        }
      })

    assert {:ok, []} = Policy.check(config, %{}, ctx())
  end

  test "refuses host binds outside the workspace by default" do
    config = compose(%{"app" => %{"volumes" => [bind("/home/mona/.ssh", "/root/.ssh")]}})
    assert {:error, [message]} = Policy.check(config, %{}, ctx())
    assert message =~ "app"
    assert message =~ "/home/mona/.ssh"
  end

  test "host binds can be downgraded to a warning" do
    config = compose(%{"app" => %{"volumes" => [bind("/home/mona/.ssh", "/root/.ssh")]}})
    assert {:ok, [warning]} = Policy.check(config, %{}, ctx(%{host_bind: :warn}))
    assert warning =~ "/home/mona/.ssh"
  end

  test "always refuses binds that expose protected paths, whatever the rules" do
    for source <- [
          "/",
          "/run",
          "/run/foreman/envs",
          "/var/lib/foreman-agent/identity.json",
          "/srv/foreman/envs/e2/workspace",
          "/srv/foreman/envs/e1/meta"
        ] do
      config = compose(%{"app" => %{"volumes" => [bind(source, "/x")]}})

      assert {:error, [message]} = Policy.check(config, %{}, ctx(%{host_bind: :allow})),
             "expected #{source} to be refused"

      assert message =~ "protected"
    end
  end

  test "refuses mounting the secrets directory anywhere but read-only at /run/foreman" do
    config = compose(%{"app" => %{"volumes" => [bind(@secrets, "/elsewhere")]}})
    assert {:error, _} = Policy.check(config, %{}, ctx(%{host_bind: :allow}))
  end

  test "flags the Docker socket" do
    config =
      compose(%{"app" => %{"volumes" => [bind("/var/run/docker.sock", "/var/run/docker.sock")]}})

    assert {:error, [message]} = Policy.check(config, %{}, ctx())
    assert message =~ "Docker socket"
  end

  test "refuses env_file, secrets and configs read from outside the workspace" do
    config =
      compose(
        %{
          "app" => %{
            "env_file" => [%{"path" => "/etc/foreman-agent/agent.env", "required" => true}]
          }
        },
        %{
          "secrets" => %{"k" => %{"file" => "/root/key"}},
          "configs" => %{"c" => %{"file" => @workspace <> "/ok"}}
        }
      )

    assert {:error, messages} = Policy.check(config, %{}, ctx(%{host_bind: :allow}))
    assert Enum.any?(messages, &(&1 =~ "/etc/foreman-agent/agent.env"))
    assert Enum.any?(messages, &(&1 =~ "/root/key"))
    refute Enum.any?(messages, &(&1 =~ "/ok"))
  end

  test "refuses build contexts outside the workspace" do
    config = compose(%{"app" => %{"build" => %{"context" => "/"}}})
    assert {:error, [message]} = Policy.check(config, %{}, ctx(%{host_bind: :allow}))
    assert message =~ "build context"
  end

  test "refuses privileged services and host namespaces by default" do
    config =
      compose(%{
        "app" => %{"privileged" => true},
        "net" => %{"network_mode" => "host"},
        "pid" => %{"pid" => "host"}
      })

    assert {:error, messages} = Policy.check(config, %{}, ctx())
    assert Enum.any?(messages, &(&1 =~ "privileged"))
    assert Enum.any?(messages, &(&1 =~ "host network"))
    assert Enum.any?(messages, &(&1 =~ "host PID"))
  end

  test "a box can open up privileged and host namespaces, as an exception" do
    config =
      compose(%{"app" => %{"privileged" => true}, "net" => %{"network_mode" => "host"}})

    assert {:ok, []} =
             Policy.check(config, %{}, ctx(%{privileged: :allow, host_namespace: :allow}))

    assert {:ok, warnings} =
             Policy.check(config, %{}, ctx(%{privileged: :warn, host_namespace: :warn}))

    assert length(warnings) == 2
  end

  test "refuses capabilities that amount to root on the box, and allows the rest" do
    for cap <- [
          "ALL",
          "SYS_ADMIN",
          "CAP_SYS_ADMIN",
          "SYS_MODULE",
          "SYS_RAWIO",
          "dac_read_search",
          "BPF"
        ] do
      config = compose(%{"app" => %{"cap_add" => ["NET_ADMIN", cap]}})

      assert {:error, [message]} = Policy.check(config, %{}, ctx()),
             "expected #{cap} to be refused"

      assert message =~ cap
    end

    config = compose(%{"app" => %{"cap_add" => ["NET_ADMIN", "NET_RAW", "SYS_PTRACE"]}})
    assert {:ok, []} = Policy.check(config, %{}, ctx())
  end

  test "refuses the docker-in-docker feature by default" do
    devcontainer = %{"features" => %{"ghcr.io/devcontainers/features/docker-in-docker:2" => %{}}}
    assert {:error, [message]} = Policy.check(compose(%{"app" => %{}}), devcontainer, ctx())
    assert message =~ "docker-in-docker"

    assert {:ok, [warning]} =
             Policy.check(compose(%{"app" => %{}}), devcontainer, ctx(%{privileged: :warn}))

    assert warning == message
  end

  test "checks privileged and capAdd in devcontainer.json" do
    devcontainer = %{"privileged" => true, "capAdd" => ["SYS_ADMIN"]}
    assert {:error, messages} = Policy.check(compose(%{"app" => %{}}), devcontainer, ctx())
    assert Enum.any?(messages, &(&1 =~ "devcontainer.json sets privileged"))
    assert Enum.any?(messages, &(&1 =~ "SYS_ADMIN"))
  end

  test "checks devcontainer.json mounts too" do
    devcontainer = %{
      "mounts" => [
        "source=/etc,target=/host-etc,type=bind",
        %{"source" => "x", "target" => "/x", "type" => "volume"}
      ]
    }

    assert {:error, [message]} = Policy.check(compose(%{"app" => %{}}), devcontainer, ctx())
    assert message =~ "/etc"
  end

  test "flags host devices" do
    config =
      compose(%{"app" => %{"devices" => [%{"source" => "/dev/sda", "target" => "/dev/sda"}]}})

    assert {:error, [message]} = Policy.check(config, %{}, ctx())
    assert message =~ "/dev/sda"
  end

  # Tailscale runs in userspace mode, so a TUN device is only left over
  # from a repo's own Tailscale setup. Say so, rather than just refusing.
  test "flags the TUN device, saying Foreman doesn't need it" do
    config =
      compose(%{"app" => %{"devices" => ["/dev/net/tun:/dev/net/tun"]}})

    assert {:error, [message]} = Policy.check(config, %{}, ctx())
    assert message =~ "/dev/net/tun"
    assert message =~ "Tailscale"
  end

  test "refuses the devcontainer CLI's own labels on a service, which change what it checks" do
    for labels <- [
          %{"devcontainer.local_folder" => "/srv/foreman/envs/e1/workspace/storefront"},
          ["devcontainer.metadata=[]"]
        ] do
      assert {:error, [message]} =
               Policy.check(compose(%{"app" => %{"labels" => labels}}), %{}, ctx())

      assert message =~ "service 'app'"
      assert message =~ "devcontainer."
    end

    assert {:ok, []} =
             Policy.check(
               compose(%{"app" => %{"labels" => %{"com.example.team" => "web"}}}),
               %{},
               ctx(%{privileged: :allow})
             )
  end

  describe "the resolved configuration (features included)" do
    defp resolved(features, merged \\ %{}) do
      %{
        "mergedConfiguration" => merged,
        "featuresConfiguration" => %{
          "featureSets" =>
            for {id, meta} <- features do
              %{"sourceInformation" => %{"userFeatureId" => id}, "features" => [meta]}
            end
        }
      }
    end

    test "refuses a feature whose own metadata asks for privileged, and names it" do
      config =
        resolved(
          [{"ghcr.io/acme/features/sneaky:1", %{"id" => "sneaky", "privileged" => true}}],
          %{
            "privileged" => true
          }
        )

      assert {:error, [message]} = Policy.check_resolved(config, ctx())
      assert message =~ "ghcr.io/acme/features/sneaky:1"
      assert message =~ "privileged"
    end

    test "refuses dangerous capabilities from features and allows the Foreman feature's" do
      config =
        resolved([
          {"ghcr.io/acme/features/caps:1", %{"id" => "caps", "capAdd" => ["SYS_MODULE"]}},
          {"ghcr.io/ntodd/foreman-features/foreman:1",
           %{"id" => "foreman", "capAdd" => ["NET_ADMIN", "NET_RAW"]}}
        ])

      assert {:error, [message]} = Policy.check_resolved(config, ctx())
      assert message =~ "ghcr.io/acme/features/caps:1"
      assert message =~ "SYS_MODULE"
    end

    test "checks mounts that features add" do
      config =
        resolved([], %{
          "mounts" => [
            %{
              "source" => "/var/run/docker.sock",
              "target" => "/var/run/docker-host.sock",
              "type" => "bind"
            },
            %{
              "source" => "dind-var-lib-docker",
              "target" => "/var/lib/docker",
              "type" => "volume"
            }
          ]
        })

      assert {:error, [message]} = Policy.check_resolved(config, ctx())
      assert message =~ "Docker socket"
    end

    test "says when a refused feature is one the user added, not the repo's" do
      ref = "ghcr.io/mona/features/root:1"

      config =
        resolved([
          {ref, %{"id" => "root", "privileged" => true, "capAdd" => ["SYS_ADMIN"]}},
          {"ghcr.io/acme/features/caps:1", %{"id" => "caps", "capAdd" => ["SYS_MODULE"]}}
        ])

      ctx = Map.put(ctx(), :user_features, [ref])
      assert {:error, messages} = Policy.check_resolved(config, ctx)

      assert [privileged, caps] = Enum.filter(messages, &(&1 =~ ref))
      assert privileged =~ "your feature #{ref} (from your Foreman settings)"
      assert caps =~ "your feature #{ref} (from your Foreman settings)"

      assert [repo] = Enum.filter(messages, &(&1 =~ "caps:1"))
      assert repo =~ "feature ghcr.io/acme/features/caps:1"
      refute repo =~ "your feature"
    end

    test "still refuses privileged when it can't tell where it came from" do
      assert {:error, [message]} =
               Policy.check_resolved(resolved([], %{"privileged" => true}), ctx())

      assert message =~ "privileged"
    end

    test "passes a clean configuration, and anything the box has opened up" do
      clean =
        resolved([{"ghcr.io/devcontainers/features/node:1", %{"id" => "node"}}], %{
          "capAdd" => ["NET_ADMIN"]
        })

      assert {:ok, []} = Policy.check_resolved(clean, ctx())

      dind =
        resolved(
          [
            {"ghcr.io/devcontainers/features/docker-in-docker:2",
             %{"id" => "docker-in-docker", "privileged" => true}}
          ],
          %{"privileged" => true}
        )

      assert {:ok, []} = Policy.check_resolved(dind, ctx(%{privileged: :allow}))
    end
  end
end
