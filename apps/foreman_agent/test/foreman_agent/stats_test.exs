defmodule ForemanAgent.StatsTest do
  use ExUnit.Case, async: true

  import Mox

  alias ForemanAgent.{Config, DockerMock, RunnerMock, Stats}

  @e1 "6f1c1d1e-9a3b-4c1f-8f5e-2d7a9b0c1e2f"

  setup :verify_on_exit!

  defp ctx do
    %{
      config: %Config{envs_root: "/srv/foreman/envs"},
      runner: RunnerMock,
      docker: DockerMock,
      log: fn _, _ -> :ok end
    }
  end

  defp container(id, service, state) do
    %{
      "Id" => id,
      "State" => state,
      "Labels" => %{
        "foreman.env_id" => @e1,
        "foreman.slug" => "a-1",
        "com.docker.compose.service" => service
      }
    }
  end

  test "reports capacity and per-environment usage" do
    stub(DockerMock, :info, fn ->
      {:ok, %{"NCPU" => 16, "MemTotal" => 64 * 1024 * 1024 * 1024}}
    end)

    stub(RunnerMock, :run, fn "df", ["-Pk", "/srv/foreman/envs"], _ ->
      {:ok,
       %{
         status: 0,
         output:
           "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1048576000 524288000 524288000 50% /\n"
       }}
    end)

    stub(DockerMock, :list_containers, fn ["foreman.env_id"] ->
      {:ok,
       [
         container("aaa111aaa111", "app", "running"),
         container("bbb222bbb222", "db", "running"),
         container("ccc333ccc333", "x", "exited")
       ]}
    end)

    stub(DockerMock, :stats, fn
      "aaa111aaa111" ->
        {:ok,
         %{
           "cpu_stats" => %{
             "cpu_usage" => %{"total_usage" => 2_000_000},
             "system_cpu_usage" => 20_000_000,
             "online_cpus" => 16
           },
           "precpu_stats" => %{
             "cpu_usage" => %{"total_usage" => 1_000_000},
             "system_cpu_usage" => 10_000_000
           },
           "memory_stats" => %{
             "usage" => 3 * 1024 * 1024 * 1024,
             "stats" => %{"inactive_file" => 1024 * 1024 * 1024}
           }
         }}

      "bbb222bbb222" ->
        {:ok,
         %{
           "cpu_stats" => %{
             "cpu_usage" => %{"total_usage" => 500_000},
             "system_cpu_usage" => 20_000_000,
             "online_cpus" => 16
           },
           "precpu_stats" => %{
             "cpu_usage" => %{"total_usage" => 0},
             "system_cpu_usage" => 10_000_000
           },
           "memory_stats" => %{"usage" => 512 * 1024 * 1024, "stats" => %{}}
         }}
    end)

    assert {:ok, stats} = Stats.collect(ctx())

    assert stats.capacity == %{
             cpus: 16,
             memory_mb: 65_536,
             disk_mb: 1_024_000,
             disk_free_mb: 512_000
           }

    # app: 1e6/1e7 * 16 cores = 160%; db: 0.5e6/1e7 * 16 = 80%
    assert %{cpu_percent: cpu, memory_mb: mem} = stats.environments[@e1]
    assert_in_delta cpu, 240.0, 0.01
    assert mem == 2048 + 512
  end

  test "survives a container that vanishes between list and stats" do
    stub(DockerMock, :info, fn -> {:ok, %{"NCPU" => 4, "MemTotal" => 1024 * 1024 * 1024}} end)
    stub(RunnerMock, :run, fn "df", _, _ -> {:ok, %{status: 1, output: "df: no such file"}} end)

    stub(DockerMock, :list_containers, fn _ ->
      {:ok, [container("aaa111aaa111", "app", "running")]}
    end)

    stub(DockerMock, :stats, fn _ -> {:error, {:http, 404, %{}}} end)

    assert {:ok, %{capacity: %{cpus: 4, disk_mb: 0}, environments: envs}} = Stats.collect(ctx())
    assert envs == %{@e1 => %{cpu_percent: 0.0, memory_mb: 0}}
  end
end
