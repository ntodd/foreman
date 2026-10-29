defmodule ForemanAgent.Env.ComposeScanTest do
  @moduledoc """
  The repo's compose files, read before compose reads them. Compose reads
  some files while it parses (env files, label files, included and
  extended compose files), so by the time `docker compose config` shows a
  config, it has already read them, and may have quoted them in an error
  or folded them into a service's environment. These are checked first,
  as written, and anything the policy doesn't know is refused.
  """
  use ExUnit.Case, async: true

  alias ForemanAgent.Env.{ComposeScan, Policy}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "envs/e1/workspace")
    clone = Path.join(workspace, "repo")
    other_secrets = Path.join(tmp, "run/e2/secrets.env")
    identity = Path.join(tmp, "data/identity.json")
    outside = Path.join(tmp, "outside")

    for dir <- [Path.join(clone, ".devcontainer"), Path.dirname(other_secrets), outside],
        do: File.mkdir_p!(dir)

    File.mkdir_p!(Path.dirname(identity))
    File.write!(other_secrets, "DATABASE_URL=postgres://other\n")
    File.write!(identity, ~s({"agent_id":"a1","private_key":"S0VZ"}))
    File.write!(Path.join(outside, "host.env"), "A=1\n")

    ctx = %{
      workspace_root: workspace,
      secrets_dir: Path.join(tmp, "run/e1"),
      protected: [Path.join(tmp, "run"), Path.join(tmp, "envs/e2"), Path.join(tmp, "data")],
      rules: Policy.default_rules(),
      project: "s-1"
    }

    %{
      ctx: ctx,
      clone: clone,
      outside: outside,
      other_secrets: other_secrets,
      identity: identity
    }
  end

  defp write(clone, rel, content) do
    path = Path.join(clone, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  # Scans .devcontainer/docker-compose.yml (and whatever it pulls in).
  defp check(%{clone: clone, ctx: ctx}, yaml, opts \\ []) do
    main = write(clone, ".devcontainer/docker-compose.yml", yaml)
    ctx = Map.update!(ctx, :rules, &Map.merge(&1, Keyword.get(opts, :rules, %{})))

    with {:ok, facts} <- ComposeScan.scan(clone, [main]) do
      Policy.check_sources(facts, ctx)
    end
  end

  defp refused(result) do
    assert {:error, messages} = result
    Enum.join(List.wrap(messages), "\n")
  end

  test "reads with the Node it's given, and a missing one is an error, not a pass", ctx do
    main = write(ctx.clone, ".devcontainer/docker-compose.yml", "services: {app: {image: alpine}}\n")

    assert {:ok, _facts} = ComposeScan.scan(ctx.clone, [main], node: System.find_executable("node"))

    assert {:error, message} =
             ComposeScan.scan(ctx.clone, [main], node: Path.join(ctx.outside, "no-node"))

    assert message =~ "Node"
    assert message =~ Path.join(ctx.outside, "no-node")
  end

  test "an ordinary compose file is fine", ctx do
    write(ctx.clone, ".devcontainer/app.env", "A=1\n")

    assert {:ok, []} =
             check(ctx, """
             name: demo
             services:
               app:
                 image: alpine
                 env_file: [app.env, {path: ./app.env, required: false}]
                 ports: !reset []
                 environment: !override {A: "1"}
                 build: {context: .., dockerfile: .devcontainer/Dockerfile}
                 x-notes: anything
             x-common: &common {restart: "no"}
             volumes: {data: {}}
             """)
  end

  describe "files compose reads while it parses" do
    test "include's env_file can't read another environment's secrets", ctx do
      write(ctx.clone, ".devcontainer/inc.yml", """
      services:
        app: {image: alpine, environment: {STOLEN: "${DATABASE_URL}"}}
      """)

      message =
        refused(
          check(ctx, """
          include:
            - path: inc.yml
              env_file: #{ctx.other_secrets}
          """)
        )

      assert message =~ "env_file"
      assert message =~ "protected"
    end

    test "a label_file can't read the agent's key", ctx do
      message =
        refused(check(ctx, "services:\n  app: {image: alpine, label_file: #{ctx.identity}}\n"))

      assert message =~ "label_file"
      refute message =~ "S0VZ"
    end

    test "a service env_file outside the workspace is a host file", ctx do
      assert refused(
               check(
                 ctx,
                 "services:\n  app: {image: alpine, env_file: #{ctx.outside}/host.env}\n"
               )
             ) =~ "outside the workspace"

      assert {:ok, [_warning]} =
               check(
                 ctx,
                 "services:\n  app: {image: alpine, env_file: #{ctx.outside}/host.env}\n",
                 rules: %{host_file: :warn}
               )
    end

    test "a relative path that climbs out of the workspace", ctx do
      assert refused(
               check(
                 ctx,
                 "services:\n  app: {image: alpine, env_file: ../../../../outside/host.env}\n"
               )
             ) =~ "outside the workspace"
    end

    test "a path built from variables can't be checked", ctx do
      assert refused(
               check(ctx, "services:\n  app: {image: alpine, env_file: \"${X:-/etc/passwd}\"}\n")
             ) =~ "variables"
    end

    test "an env_file hidden in an anchor and merged into a service", ctx do
      assert refused(
               check(ctx, """
               x-base: &base
                 env_file: #{ctx.other_secrets}
               services:
                 app:
                   <<: *base
                   image: alpine
               """)
             ) =~ "protected"
    end

    test "a merged value counts even when the service sets its own", ctx do
      write(ctx.clone, ".devcontainer/ok.env", "A=1\n")

      assert refused(
               check(ctx, """
               x-base: &base {label_file: #{ctx.identity}}
               services:
                 app:
                   <<: [*base]
                   label_file: ok.env
                   image: alpine
               """)
             ) =~ "protected"
    end

    test "an include chain is followed", ctx do
      write(ctx.clone, ".devcontainer/a/one.yml", "include: [../b/two.yml]\n")

      write(
        ctx.clone,
        ".devcontainer/b/two.yml",
        "services:\n  app: {image: alpine, env_file: #{ctx.other_secrets}}\n"
      )

      assert refused(check(ctx, "include: [a/one.yml]\n")) =~ "protected"
    end

    test "a service extended from an included file is followed", ctx do
      write(ctx.clone, ".devcontainer/inc.yml", """
      services:
        app:
          extends: {file: ext.yml, service: base}
      """)

      write(ctx.clone, ".devcontainer/ext.yml", """
      services:
        base: {image: alpine, label_file: #{ctx.identity}}
      """)

      assert refused(check(ctx, "include: [inc.yml]\n")) =~ "protected"
    end

    test "an extends file outside the workspace isn't read, and is a host file", ctx do
      File.write!(Path.join(ctx.outside, "base.yml"), "services: {base: {image: alpine}}\n")

      assert refused(
               check(ctx, """
               services:
                 app: {extends: {file: #{ctx.outside}/base.yml, service: base}}
               """)
             ) =~ "outside the workspace"
    end

    test "an include that's a symlink out of the workspace", ctx do
      evil = Path.join(ctx.outside, "evil.yml")
      File.write!(evil, "services: {app: {image: alpine}}\n")
      File.ln_s!(evil, Path.join(ctx.clone, ".devcontainer/inc.yml"))

      assert refused(check(ctx, "include: [inc.yml]\n")) =~ "outside the workspace"
    end

    test "an include's project_directory outside the workspace", ctx do
      write(ctx.clone, ".devcontainer/inc.yml", "services: {app: {image: alpine}}\n")

      assert refused(
               check(ctx, """
               include:
                 - path: [inc.yml]
                   project_directory: #{ctx.outside}
               """)
             ) =~ "outside the workspace"
    end

    test "a remote include", ctx do
      assert refused(check(ctx, "include: [\"oci://example.com/compose:1\"]\n")) =~ "remote"
    end

    test "an include cycle ends", ctx do
      write(ctx.clone, ".devcontainer/a.yml", "include: [b.yml]\n")
      write(ctx.clone, ".devcontainer/b.yml", "include: [a.yml]\n")

      assert {:ok, []} = check(ctx, "include: [a.yml]\n")
    end

    test "too many files to read", ctx do
      for i <- 1..60,
          do: write(ctx.clone, ".devcontainer/f#{i}.yml", "include: [f#{i + 1}.yml]\n")

      assert {:error, message} = check(ctx, "include: [f1.yml]\n")
      assert message =~ "too many"
    end
  end

  describe "YAML compose would read differently" do
    test "an unknown tag isn't guessed at", ctx do
      assert {:error, message} = check(ctx, "services:\n  app: !weird {image: alpine}\n")
      assert message =~ "docker-compose.yml"
    end

    test "aliases that expand without end", ctx do
      bomb =
        Enum.map_join(1..12, "\n", fn i ->
          "x-l#{i}: &l#{i} [" <> Enum.map_join(1..10, ", ", fn _ -> "*l#{i - 1}" end) <> "]"
        end)

      assert {:error, _} = check(ctx, "x-l0: &l0 [a]\n#{bomb}\nservices: {}\n")
    end
  end

  describe "keys the policy doesn't know" do
    test "an unknown top-level key is refused, unless the box allows it", ctx do
      yaml = "models: {m: {model: ai/x}}\nservices: {app: {image: alpine}}\n"

      assert refused(check(ctx, yaml)) =~ "models"
      assert {:ok, []} = check(ctx, yaml, rules: %{compose_keys: :allow})
    end

    test "an unknown service key is refused; extension keys are fine", ctx do
      assert refused(check(ctx, "services:\n  app: {image: alpine, cgroup_parent: x}\n")) =~
               "service 'app' uses cgroup_parent"

      assert {:ok, []} = check(ctx, "services:\n  app: {image: alpine, x-anything: 1}\n")
    end

    test "gpus has been reviewed (the policy checks it with GPU reservations)", ctx do
      assert {:ok, []} = check(ctx, "services:\n  app: {image: alpine, gpus: all}\n")
    end

    test "an unknown key inside a merge is still seen", ctx do
      assert refused(
               check(ctx, """
               x-base: &base {runtime: sneaky}
               services:
                 app: {<<: *base, image: alpine}
               """)
             ) =~ "runtime"
    end

    test "a provider service runs a program on the box, whatever the box allows", ctx do
      message =
        refused(
          check(ctx, "services:\n  p: {provider: {type: ./evil}}\n",
            rules: %{compose_keys: :allow}
          )
        )

      assert message =~ "provider"
    end

    test "use_api_socket is the Docker socket", ctx do
      assert refused(check(ctx, "services:\n  app: {image: alpine, use_api_socket: true}\n")) =~
               "Docker socket"
    end
  end
end
