defmodule ForemanAgent.Vm.IncusTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, RunnerMock}
  alias ForemanAgent.Vm.Incus

  @env_id "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"
  @name "fm-6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup :verify_on_exit!

  setup do
    config = %Config{incus: "incus", vm_image: "foreman-env", vm_profiles: ["foreman-env"]}
    %{ctx: %{config: config, runner: RunnerMock, log: fn _, _ -> :ok end}}
  end

  # Every incus call goes through sh with stdin closed: `incus init` and
  # friends read YAML from a stdin that isn't a terminal, and the runner's
  # stdin is a pipe that never closes.
  defp expect_incus(args, result) do
    expect(RunnerMock, :run, fn "sh", ["-c", script, "incus" | rest], _opts ->
      assert script =~ "</dev/null"
      assert rest == args
      result
    end)
  end

  test "names a VM after its environment" do
    assert Incus.name(@env_id) == @name
  end

  test "creates a VM sized from the environment, with the box's profiles", %{ctx: ctx} do
    expect_incus(
      [
        "init",
        "foreman-env",
        @name,
        "--vm",
        "--profile",
        "default",
        "--profile",
        "foreman-env",
        "-c",
        "limits.cpu=3",
        "-c",
        "limits.memory=6144MiB",
        "-c",
        "boot.autostart=false",
        "-c",
        "security.secureboot=false",
        "-c",
        "user.foreman.env_id=#{@env_id}",
        "-c",
        "user.foreman.slug=storefront-2",
        "-d",
        "root,size=80GiB"
      ],
      {:ok, %{status: 0, output: "Creating #{@name}\n"}}
    )

    assert :ok =
             Incus.create(ctx, @name,
               env_id: @env_id,
               slug: "storefront-2",
               cpus: 3,
               memory_mb: 6144,
               disk_gb: 80
             )
  end

  test "reads a VM's state, and a missing VM is missing", %{ctx: ctx} do
    expect_incus(
      ["query", "/1.0/instances/#{@name}"],
      {:ok, %{status: 0, output: ~s({"status":"Running"})}}
    )

    assert Incus.state(ctx, @name) == {:ok, :running}

    expect_incus(
      ["query", "/1.0/instances/#{@name}"],
      {:ok, %{status: 0, output: ~s({"status":"Stopped"})}}
    )

    assert Incus.state(ctx, @name) == {:ok, :stopped}

    expect_incus(
      ["query", "/1.0/instances/#{@name}"],
      {:ok, %{status: 1, output: "Error: Instance not found\n"}}
    )

    assert Incus.state(ctx, @name) == {:ok, :missing}
  end

  test "a daemon that doesn't answer is an error, not a missing VM", %{ctx: ctx} do
    expect_incus(
      ["query", "/1.0/instances/#{@name}"],
      {:ok,
       %{
         status: 1,
         output: "Error: Get \"http://unix.socket/1.0\": dial unix: connection refused\n"
       }}
    )

    assert {:error, "incus query failed: " <> _} = Incus.state(ctx, @name)
  end

  test "lists only Foreman's VMs, with their sizes, from instances without their state",
       %{ctx: ctx} do
    instances = [
      %{
        "name" => @name,
        "type" => "virtual-machine",
        "status" => "Running",
        "config" => %{
          "user.foreman.env_id" => @env_id,
          "user.foreman.slug" => "storefront-2",
          "limits.cpu" => "4",
          "limits.memory" => "8192MiB"
        }
      },
      %{"name" => "someone-elses", "type" => "container", "status" => "Running", "config" => %{}},
      %{
        "name" => "fm-ready",
        "type" => "virtual-machine",
        "status" => "Ready",
        "config" => %{
          "user.foreman.env_id" => "11111111-1111-4111-8111-111111111111",
          "user.foreman.slug" => "api-1",
          "limits.memory" => "2GiB"
        }
      }
    ]

    # The client's first-run notice comes first on stderr, merged in.
    notice = "To start your first container, try: incus launch images:ubuntu/22.04\n"

    # Without state: what a guest reports about itself (its interfaces,
    # say) can't grow this past what the runner keeps.
    expect(RunnerMock, :run, fn "sh",
                                ["-c", _, "incus", "query", "/1.0/instances?recursion=1"],
                                opts ->
      assert opts[:keep] >= 16 * 1024 * 1024
      {:ok, %{status: 0, output: notice <> JSON.encode!(instances)}}
    end)

    assert {:ok, [running, ready]} = Incus.list(ctx)

    assert running == %{
             name: @name,
             env_id: @env_id,
             slug: "storefront-2",
             status: :running,
             cpus: 4,
             memory_mb: 8192
           }

    # A guest can mark itself Ready through the guest API; it's still running.
    assert ready.status == :running
    assert ready.memory_mb == 2048
    assert ready.cpus == nil
  end

  test "reads one VM's usage, and a guest that answers too much is an error for that VM only",
       %{ctx: ctx} do
    state = %{
      "status" => "Running",
      "cpu" => %{"usage" => 12_000_000_000},
      "memory" => %{"usage" => 1_048_576_000}
    }

    expect_incus(
      ["query", "/1.0/instances/#{@name}/state"],
      {:ok, %{status: 0, output: JSON.encode!(state)}}
    )

    assert Incus.usage(ctx, @name) ==
             {:ok, %{cpu_ns: 12_000_000_000, memory_bytes: 1_048_576_000}}

    truncated = String.slice(JSON.encode!(state), 0, 20)

    expect_incus(
      ["query", "/1.0/instances/#{@name}/state"],
      {:ok, %{status: 0, output: truncated}}
    )

    assert {:error, _} = Incus.usage(ctx, @name)
  end

  test "a VM's size and state come from one query", %{ctx: ctx} do
    expect_incus(
      ["query", "/1.0/instances/#{@name}"],
      {:ok,
       %{
         status: 0,
         output: ~s({"status":"Frozen","config":{"limits.cpu":"2","limits.memory":"4096MiB"}})
       }}
    )

    assert Incus.info(ctx, @name) == {:ok, %{status: :other, cpus: 2, memory_mb: 4096}}
  end

  test "resizes a VM", %{ctx: ctx} do
    expect_incus(
      ["config", "set", @name, "limits.cpu=8", "limits.memory=16384MiB"],
      {:ok, %{status: 0, output: ""}}
    )

    assert :ok = Incus.resize(ctx, @name, 8, 16_384)
  end

  test "starts, stops (forcing after a timeout) and deletes", %{ctx: ctx} do
    expect_incus(["start", @name], {:ok, %{status: 0, output: ""}})
    assert :ok = Incus.start(ctx, @name)

    expect_incus(
      ["stop", @name, "--timeout", "60"],
      {:ok, %{status: 1, output: "Error: timed out\n"}}
    )

    expect_incus(["stop", @name, "--force"], {:ok, %{status: 0, output: ""}})
    assert :ok = Incus.stop(ctx, @name)

    expect_incus(["delete", @name, "--force"], {:ok, %{status: 0, output: ""}})
    assert :ok = Incus.delete(ctx, @name)
  end

  test "builds exec argv with the working directory and a sorted environment" do
    assert Incus.exec_args(@name, ["git", "status"], cwd: "/srv", env: %{"B" => "2", "A" => "1"}) ==
             [
               "exec",
               @name,
               "--cwd",
               "/srv",
               "--env",
               "A=1",
               "--env",
               "B=2",
               "--",
               "git",
               "status"
             ]
  end

  test "pushes a file with its owner and mode", %{ctx: ctx} do
    expect_incus(
      [
        "file",
        "push",
        "--uid",
        "990",
        "--gid",
        "990",
        "--mode",
        "0600",
        "/tmp/op",
        "#{@name}/var/lib/foreman-agent/ops/x.op"
      ],
      {:ok, %{status: 0, output: ""}}
    )

    assert :ok =
             Incus.push(ctx, @name, "/tmp/op", "/var/lib/foreman-agent/ops/x.op",
               uid: 990,
               gid: 990,
               mode: 0o600
             )
  end
end
