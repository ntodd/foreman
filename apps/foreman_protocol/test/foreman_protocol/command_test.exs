defmodule ForemanProtocol.CommandTest do
  use ExUnit.Case, async: true

  alias ForemanProtocol.Command

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @op_id "0b8e3a6c-5d2f-4e1a-9c7b-3f2e1d0c9b8a"

  defp create_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "env_id" => @env_id,
        "slug" => "storefront-2",
        "repo" => "acme/storefront",
        "clone_url" => "https://github.com/acme/storefront.git",
        "branch" => "main",
        "config_path" => ".devcontainer/devcontainer.json",
        "files" => %{"secrets.env" => "export A='1'\n", "github-token" => "ghu_x"},
        "compose_env" => %{"NEON_API_KEY" => "secret"},
        "limits" => %{"cpus" => 2.5, "memory_mb" => 4096},
        "dotfiles" => %{"repository" => "https://github.com/mona/dotfiles.git"},
        "tailscale" => %{"enabled" => true, "tags" => ["tag:foreman-env"]}
      },
      overrides
    )
  end

  describe "new/3" do
    test "builds an env.create command with atom keys" do
      assert {:ok, %Command{} = cmd} = Command.new("env.create", create_payload(), op_id: @op_id)

      assert cmd.op_id == @op_id
      assert cmd.type == "env.create"
      assert cmd.payload.env_id == @env_id
      assert cmd.payload.slug == "storefront-2"
      assert cmd.payload.files == %{"secrets.env" => "export A='1'\n", "github-token" => "ghu_x"}
      assert cmd.payload.compose_env == %{"NEON_API_KEY" => "secret"}
      assert cmd.payload.limits == %{cpus: 2.5, memory_mb: 4096}
      assert cmd.payload.dotfiles.repository == "https://github.com/mona/dotfiles.git"
      assert cmd.payload.tailscale == %{enabled: true, tags: ["tag:foreman-env"]}
    end

    test "generates an op_id when none is given" do
      assert {:ok, cmd} = Command.new("box.inventory", %{})
      assert cmd.op_id =~ ~r/^[0-9a-f-]{36}$/
    end

    test "accepts atom keys" do
      assert {:ok, cmd} = Command.new("env.stop", %{env_id: @env_id, slug: "storefront-2"})
      assert cmd.payload == %{env_id: @env_id, slug: "storefront-2"}
    end

    test "applies defaults for optional fields" do
      payload =
        create_payload()
        |> Map.drop(["config_path", "limits", "dotfiles", "tailscale", "compose_env"])

      assert {:ok, cmd} = Command.new("env.create", payload)
      assert cmd.payload.config_path == ".devcontainer/devcontainer.json"
      assert cmd.payload.compose_env == %{}
      assert cmd.payload.limits == %{}
      assert cmd.payload.tailscale == %{enabled: false, tags: []}
      refute Map.has_key?(cmd.payload, :dotfiles)
    end

    test "rejects unknown command types" do
      assert {:error, {:unknown_type, "exec"}} = Command.new("exec", %{"cmd" => "rm -rf /"})
    end

    test "rejects missing required fields" do
      assert {:error, errors} = Command.new("env.stop", %{"env_id" => @env_id})
      assert {"slug", "is required"} in errors
    end

    test "rejects unknown fields rather than passing them through" do
      assert {:error, errors} =
               Command.new("env.stop", %{"env_id" => @env_id, "slug" => "a", "shell" => "x"})

      assert {"shell", "is not allowed"} in errors
    end

    test "rejects slugs that are not DNS labels" do
      for bad <- [
            "Storefront",
            "-storefront",
            "storefront-",
            "store_front",
            "store.front",
            String.duplicate("a", 64),
            ""
          ] do
        assert {:error, errors} = Command.new("env.stop", %{"env_id" => @env_id, "slug" => bad})
        assert Enum.any?(errors, &match?({"slug", _}, &1)), "expected #{inspect(bad)} to fail"
      end
    end

    test "rejects env ids that are not UUIDs" do
      assert {:error, errors} = Command.new("env.stop", %{"env_id" => "../../etc", "slug" => "a"})
      assert {"env_id", "must be a UUID"} in errors
    end

    test "rejects secret file names outside the allowlist" do
      payload = %{"env_id" => @env_id, "files" => %{"../../.bashrc" => "x"}}
      assert {:error, errors} = Command.new("env.secrets.write", payload)
      assert {"files", "contains a file name that is not allowed: ../../.bashrc"} in errors
    end

    test "rejects compose env names that are not shell identifiers" do
      payload = create_payload(%{"compose_env" => %{"BAD NAME" => "x"}})
      assert {:error, errors} = Command.new("env.create", payload)
      assert {"compose_env", "contains an invalid variable name: BAD NAME"} in errors
    end

    test "rejects compose env names the agent sets itself" do
      for name <- ~w(PATH HOME DOCKER_HOST DOCKER_CONFIG COMPOSE_PROJECT_NAME LD_PRELOAD) do
        payload = create_payload(%{"compose_env" => %{name => "x"}})
        assert {:error, errors} = Command.new("env.create", payload)
        assert {"compose_env", "contains a reserved variable name: #{name}"} in errors
      end
    end

    test "rejects branches that could be read as options or are not valid refs" do
      for bad <- [
            "-upload-pack=evil",
            "a..b",
            "a b",
            "a~1",
            "a^",
            "a:b",
            "/a",
            "a/",
            "a.lock",
            ""
          ] do
        payload = create_payload(%{"branch" => bad})
        assert {:error, errors} = Command.new("env.create", payload)
        assert Enum.any?(errors, &match?({"branch", _}, &1)), "expected #{inspect(bad)} to fail"
      end

      assert {:ok, _} =
               Command.new("env.create", create_payload(%{"branch" => "feature/foo-1.2"}))
    end

    test "only accepts https clone URLs and repo names of the owner/name form" do
      for bad <- [
            "git@github.com:acme/storefront.git",
            "ext::sh -c touch% /tmp/pwned",
            "file:///etc",
            "-u"
          ] do
        assert {:error, errors} = Command.new("env.create", create_payload(%{"clone_url" => bad}))

        assert Enum.any?(errors, &match?({"clone_url", _}, &1)),
               "expected #{inspect(bad)} to fail"
      end

      assert {:error, errors} = Command.new("env.create", create_payload(%{"repo" => "../x"}))
      assert Enum.any?(errors, &match?({"repo", _}, &1))
    end

    test "rejects config paths that escape the clone" do
      for bad <- [
            "../x/devcontainer.json",
            "/etc/devcontainer.json",
            ".devcontainer/../../x.json"
          ] do
        assert {:error, errors} =
                 Command.new("env.create", create_payload(%{"config_path" => bad}))

        assert Enum.any?(errors, &match?({"config_path", _}, &1)),
               "expected #{inspect(bad)} to fail"
      end

      assert {:ok, _} =
               Command.new(
                 "env.create",
                 create_payload(%{"config_path" => ".devcontainer/web/devcontainer.json"})
               )
    end

    test "validates restart modes and changed variable names" do
      base = %{
        "env_id" => @env_id,
        "slug" => "a",
        "mode" => "affected",
        "changed" => ["NEON_API_KEY"]
      }

      assert {:ok, cmd} = Command.new("env.restart", base)
      assert cmd.payload.mode == "affected"

      assert {:error, errors} = Command.new("env.restart", %{base | "mode" => "nuke"})
      assert Enum.any?(errors, &match?({"mode", _}, &1))

      assert {:error, errors} = Command.new("env.restart", %{base | "changed" => ["A; rm"]})
      assert Enum.any?(errors, &match?({"changed", _}, &1))
    end

    test "validates agent.update" do
      payload = %{
        "version" => "0.2.0",
        "url" => "https://foreman.example.ts.net/agent/releases/0.2.0/linux-arm64",
        "sha256" => String.duplicate("a", 64),
        "signature" => Base.encode64(String.duplicate("s", 64))
      }

      assert {:ok, _} = Command.new("agent.update", payload)
      assert {:error, _} = Command.new("agent.update", %{payload | "sha256" => "nothex"})
      assert {:error, _} = Command.new("agent.update", %{payload | "version" => "1.0; rm"})
    end

    test "registry auth is optional but must be complete when given" do
      auth = %{"host" => "ghcr.io", "username" => "machine", "token" => "ghp_x"}
      assert {:ok, cmd} = Command.new("env.create", create_payload(%{"registry_auth" => [auth]}))
      assert [%{host: "ghcr.io"}] = cmd.payload.registry_auth

      assert {:error, _} =
               Command.new(
                 "env.create",
                 create_payload(%{"registry_auth" => [Map.delete(auth, "token")]})
               )
    end
  end

  describe "wire format" do
    test "round-trips through to_wire/from_wire" do
      {:ok, cmd} = Command.new("env.create", create_payload(), op_id: @op_id)
      wire = Command.to_wire(cmd)

      assert wire["type"] == "env.create"
      assert wire["op_id"] == @op_id
      assert wire["payload"]["limits"] == %{"cpus" => 2.5, "memory_mb" => 4096}
      assert {:ok, ^cmd} = Command.from_wire(wire)
    end

    test "from_wire validates like new/3" do
      assert {:error, _} =
               Command.from_wire(%{"op_id" => @op_id, "type" => "exec", "payload" => %{}})

      assert {:error, _} = Command.from_wire(%{"type" => "box.inventory", "payload" => %{}})
      assert {:error, _} = Command.from_wire("garbage")
    end

    test "inspect redacts secret-bearing fields" do
      {:ok, cmd} = Command.new("env.create", create_payload(), op_id: @op_id)
      output = inspect(cmd)
      refute output =~ "ghu_x"
      refute output =~ "secret"
      assert output =~ "env.create"
    end
  end
end
