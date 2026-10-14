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

  test "warns about privileged services and host namespaces by default" do
    config =
      compose(%{
        "app" => %{"privileged" => true},
        "net" => %{"network_mode" => "host"},
        "pid" => %{"pid" => "host"}
      })

    assert {:ok, warnings} = Policy.check(config, %{}, ctx())
    assert Enum.any?(warnings, &(&1 =~ "privileged"))
    assert Enum.any?(warnings, &(&1 =~ "host network"))
    assert Enum.any?(warnings, &(&1 =~ "host PID"))
  end

  test "privileged can be refused per box" do
    config = compose(%{"app" => %{"privileged" => true}})
    assert {:error, _} = Policy.check(config, %{}, ctx(%{privileged: :refuse}))
  end

  test "treats the docker-in-docker feature as privileged" do
    devcontainer = %{"features" => %{"ghcr.io/devcontainers/features/docker-in-docker:2" => %{}}}
    assert {:ok, [warning]} = Policy.check(compose(%{"app" => %{}}), devcontainer, ctx())
    assert warning =~ "docker-in-docker"
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

  test "flags extra devices other than the TUN device" do
    config =
      compose(%{
        "app" => %{
          "devices" => [
            %{"source" => "/dev/net/tun", "target" => "/dev/net/tun"},
            %{"source" => "/dev/sda", "target" => "/dev/sda"}
          ]
        }
      })

    assert {:error, [message]} = Policy.check(config, %{}, ctx())
    assert message =~ "/dev/sda"
  end
end
