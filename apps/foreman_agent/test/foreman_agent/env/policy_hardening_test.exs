defmodule ForemanAgent.Env.PolicyHardeningTest do
  @moduledoc """
  Ways around the policy that `docker compose config` lets through: each
  config is in the shape Compose (v5.5) really emits.
  """
  use ExUnit.Case, async: true

  alias ForemanAgent.Env.Policy

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "envs/e1/workspace")
    clone = Path.join(workspace, "repo")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(clone)
    File.mkdir_p!(Path.join(tmp, "run/e1"))
    File.mkdir_p!(outside)

    ctx = %{
      workspace_root: workspace,
      secrets_dir: Path.join(tmp, "run/e1"),
      protected: [Path.join(tmp, "run"), Path.join(tmp, "envs"), Path.join(tmp, "data")],
      rules: Policy.default_rules()
    }

    %{ctx: ctx, clone: clone, outside: outside}
  end

  defp compose(svc, extra \\ %{}) do
    services = %{"app" => Map.put_new(svc, "image", "alpine"), "db" => %{"image" => "postgres"}}
    Map.merge(%{"name" => "s-1", "services" => services}, extra)
  end

  defp bind(source, target), do: %{"type" => "bind", "source" => source, "target" => target}

  defp loosen(ctx, rules), do: %{ctx | rules: Map.merge(ctx.rules, rules)}

  defp resolved(merged, features \\ []) do
    %{
      "configuration" => %{},
      "mergedConfiguration" => merged,
      "featuresConfiguration" => %{
        "featureSets" =>
          for {id, feature} <- features do
            %{"sourceInformation" => %{"userFeatureId" => id}, "features" => [feature]}
          end
      }
    }
  end

  describe "symlinks in the workspace" do
    test "a bind source that links outside the workspace is a host bind", ctx do
      File.ln_s!(ctx.outside, Path.join(ctx.clone, "hostlink"))
      config = compose(%{"volumes" => [bind(Path.join(ctx.clone, "hostlink"), "/host")]})

      assert {:error, [message]} = Policy.check(config, %{}, ctx.ctx)
      assert message =~ ctx.outside
    end

    test "a link to / exposes protected paths, whatever the box allows", ctx do
      File.ln_s!("/", Path.join(ctx.clone, "root"))
      config = compose(%{"volumes" => [bind(Path.join(ctx.clone, "root/"), "/host")]})
      loose = loosen(ctx.ctx, %{host_bind: :allow, docker_socket: :allow})

      assert {:error, [_ | _]} = Policy.check(config, %{}, loose)
    end

    test "env_files and devcontainer.json mounts are resolved too", ctx do
      File.ln_s!(ctx.outside, Path.join(ctx.clone, "hostlink"))
      env_file = %{"path" => Path.join(ctx.clone, "hostlink/app.env"), "required" => false}

      assert {:error, [_]} = Policy.check(compose(%{"env_file" => [env_file]}), %{}, ctx.ctx)

      mount = "source=#{Path.join(ctx.clone, "hostlink")},target=/host,type=bind"
      assert {:error, [_]} = Policy.check(compose(%{}), %{"mounts" => [mount]}, ctx.ctx)
    end

    test "links that stay inside the workspace, and paths that don't exist yet, are fine", ctx do
      File.mkdir_p!(Path.join(ctx.clone, "tools/cache"))
      File.ln_s!("tools/cache", Path.join(ctx.clone, "cache"))

      config =
        compose(%{
          "volumes" => [
            bind(Path.join(ctx.clone, "cache"), "/cache"),
            bind(Path.join(ctx.clone, "not-created-yet/data"), "/data")
          ]
        })

      assert {:ok, []} = Policy.check(config, %{}, ctx.ctx)
    end
  end

  describe "host paths by other names" do
    test "a local volume whose driver_opts bind a host path", ctx do
      volumes = %{
        "data" => %{
          "name" => "s-1_data",
          "driver" => "local",
          "driver_opts" => %{"type" => "none", "o" => "bind", "device" => ctx.outside}
        }
      }

      config =
        compose(
          %{"volumes" => [%{"type" => "volume", "source" => "data", "target" => "/d"}]},
          %{"volumes" => volumes}
        )

      assert {:error, [message]} = Policy.check(config, %{}, ctx.ctx)
      assert message =~ "volume 'data'"
      assert message =~ ctx.outside
    end

    test "a local volume that mounts a host block device", ctx do
      volumes = %{
        "disk" => %{"driver_opts" => %{"type" => "ext4", "device" => "/dev/sda1"}},
        "scratch" => %{"driver_opts" => %{"type" => "tmpfs", "device" => "tmpfs"}},
        "share" => %{
          "driver_opts" => %{"type" => "nfs", "o" => "addr=10.0.0.1", "device" => ":/x"}
        }
      }

      assert {:error, [message]} =
               Policy.check(compose(%{}, %{"volumes" => volumes}), %{}, ctx.ctx)

      assert message =~ "/dev/sda1"
    end

    test "a named volume that's really another project's volume", ctx do
      volumes = %{
        "cache" => %{"name" => "s-1_cache"},
        "ts" => %{"name" => "storefront-alice-1_tailscale-state", "external" => true}
      }

      assert {:error, [message]} =
               Policy.check(compose(%{}, %{"volumes" => volumes}), %{}, ctx.ctx)

      assert message =~ "storefront-alice-1_tailscale-state"
    end

    test "binding the Docker socket's directory hits the docker_socket rule", ctx do
      config = compose(%{"volumes" => [bind("/var/run", "/h")]})

      assert {:error, [message]} = Policy.check(config, %{}, loosen(ctx.ctx, %{host_bind: :warn}))
      assert message =~ "Docker socket"
    end

    test "a Dockerfile outside the workspace", ctx do
      outside = %{"context" => ctx.clone, "dockerfile" => "/var/lib/foreman-agent/identity.json"}
      relative = %{"context" => ctx.clone, "dockerfile" => "../../../../outside/Dockerfile"}
      inside = %{"context" => ctx.clone, "dockerfile" => ".devcontainer/Dockerfile"}

      assert {:error, [_]} = Policy.check(compose(%{"build" => outside}), %{}, ctx.ctx)
      assert {:error, [_]} = Policy.check(compose(%{"build" => relative}), %{}, ctx.ctx)
      assert {:ok, []} = Policy.check(compose(%{"build" => inside}), %{}, ctx.ctx)
    end

    test "a build ssh key read from the host", ctx do
      build = %{"context" => ctx.clone, "ssh" => ["default", "deploy=/home/me/.ssh/id_ed25519"]}

      assert {:error, [message]} = Policy.check(compose(%{"build" => build}), %{}, ctx.ctx)
      assert message =~ "/home/me/.ssh/id_ed25519"
    end
  end

  describe "other containers" do
    test "refuses joining another container's namespaces or volumes", ctx do
      for svc <- [
            %{"volumes_from" => ["container:storefront-alice-1-app-1"]},
            %{"pid" => "container:storefront-alice-1-app-1"},
            %{"ipc" => "container:storefront-alice-1-app-1"},
            %{"network_mode" => "container:storefront-alice-1-app-1"}
          ] do
        assert {:error, [message]} = Policy.check(compose(svc), %{}, ctx.ctx), inspect(svc)
        assert message =~ "storefront-alice-1-app-1"
      end
    end

    test "allows sharing with a service of the same project", ctx do
      svc = %{
        "volumes_from" => ["db"],
        "pid" => "service:db",
        "ipc" => "service:db",
        "network_mode" => "service:db"
      }

      assert {:ok, []} = Policy.check(compose(svc), %{}, ctx.ctx)
    end

    test "refuses a service reference that isn't in the project", ctx do
      assert {:error, [_]} = Policy.check(compose(%{"volumes_from" => ["nope"]}), %{}, ctx.ctx)
    end
  end

  describe "isolation settings" do
    test "refuses device_cgroup_rules", ctx do
      config = compose(%{"device_cgroup_rules" => ["b *:* rwm"]})
      assert {:error, [message]} = Policy.check(config, %{}, ctx.ctx)
      assert message =~ "b *:* rwm"
    end

    test "refuses the remaining host namespaces", ctx do
      for {key, label} <- [{"userns_mode", "user"}, {"cgroup", "cgroup"}, {"uts", "UTS"}] do
        assert {:error, [message]} = Policy.check(compose(%{key => "host"}), %{}, ctx.ctx)
        assert message =~ label
      end
    end

    test "refuses security_opt that turns off confinement, and allows no-new-privileges", ctx do
      for opt <- [
            "seccomp=unconfined",
            "seccomp:unconfined",
            "apparmor=unconfined",
            "systempaths=unconfined",
            "label=disable",
            "seccomp=/etc/permissive.json"
          ] do
        assert {:error, [message]} =
                 Policy.check(compose(%{"security_opt" => [opt]}), %{}, ctx.ctx)

        assert message =~ opt
      end

      ok = compose(%{"security_opt" => ["no-new-privileges:true", "no-new-privileges"]})
      assert {:ok, []} = Policy.check(ok, %{}, ctx.ctx)
    end

    test "security_opt other than seccomp=unconfined is part of the privileged rule", ctx do
      config = compose(%{"security_opt" => ["apparmor=unconfined"]})
      assert {:ok, [_]} = Policy.check(config, %{}, loosen(ctx.ctx, %{privileged: :warn}))
      assert {:error, [_]} = Policy.check(config, %{}, loosen(ctx.ctx, %{seccomp: :allow}))

      # A custom profile is a host file and an arbitrary filter: privileged.
      custom = compose(%{"security_opt" => ["seccomp=/etc/permissive.json"]})
      assert {:error, [_]} = Policy.check(custom, %{}, loosen(ctx.ctx, %{seccomp: :allow}))
    end

    test "seccomp=unconfined has its own rule, and the refusal says how to allow it", ctx do
      for opt <- ["seccomp=unconfined", "seccomp:unconfined"] do
        config = compose(%{"security_opt" => [opt]})

        assert {:error, [message]} = Policy.check(config, %{}, ctx.ctx)
        assert message =~ "FOREMAN_POLICY=seccomp=allow"
        assert message =~ "Go and Rust"

        assert {:ok, []} = Policy.check(config, %{}, loosen(ctx.ctx, %{seccomp: :allow}))
        assert {:ok, [_]} = Policy.check(config, %{}, loosen(ctx.ctx, %{seccomp: :warn}))
        # Loosening privileged doesn't loosen seccomp.
        assert {:error, [_]} = Policy.check(config, %{}, loosen(ctx.ctx, %{privileged: :allow}))
      end
    end

    test "the official Go feature's seccomp=unconfined goes by the seccomp rule", ctx do
      go = {"ghcr.io/devcontainers/features/go:1", %{"securityOpt" => ["seccomp=unconfined"]}}

      assert {:error, [message]} = Policy.check_resolved(resolved(%{}, [go]), ctx.ctx)
      assert message =~ "ghcr.io/devcontainers/features/go:1"

      assert {:ok, []} =
               Policy.check_resolved(resolved(%{}, [go]), loosen(ctx.ctx, %{seccomp: :allow}))

      # From image metadata, with nothing declaring it.
      merged = resolved(%{"securityOpt" => ["seccomp=unconfined"]})
      assert {:ok, []} = Policy.check_resolved(merged, loosen(ctx.ctx, %{seccomp: :allow}))
      assert {:error, [_]} = Policy.check_resolved(merged, ctx.ctx)
    end

    test "checks securityOpt in devcontainer.json, features and the merged config", ctx do
      opts = ["systempaths=unconfined"]

      assert {:error, [_]} = Policy.check(compose(%{}), %{"securityOpt" => opts}, ctx.ctx)

      feature = {"ghcr.io/acme/f/x:1", %{"id" => "x", "securityOpt" => opts}}
      assert {:error, messages} = Policy.check_resolved(resolved(%{}, [feature]), ctx.ctx)
      assert Enum.any?(messages, &(&1 =~ "ghcr.io/acme/f/x:1"))

      assert {:error, [_]} = Policy.check_resolved(resolved(%{"securityOpt" => opts}), ctx.ctx)
    end

    test "refuses root capabilities in the merged config that nothing declares", ctx do
      assert {:error, [message]} =
               Policy.check_resolved(resolved(%{"capAdd" => ["SYS_ADMIN"]}), ctx.ctx)

      assert message =~ "SYS_ADMIN"

      foreman = {"./.foreman/feature", %{"id" => "foreman", "capAdd" => ["NET_ADMIN"]}}

      assert {:ok, []} =
               Policy.check_resolved(resolved(%{"capAdd" => ["NET_ADMIN"]}, [foreman]), ctx.ctx)
    end
  end
end
