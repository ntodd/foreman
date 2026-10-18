defmodule ForemanAgent.Env.PolicyGpuTest do
  @moduledoc """
  GPU reservations have a rule of their own, so a box can allow NVIDIA
  GPUs without allowing every host device. Configs are in the shape
  `docker compose config --format json` (v5.5) emits: `count: all`
  becomes -1, and `gpus: all` becomes `[{"count": -1}]`.
  """
  use ExUnit.Case, async: true

  alias ForemanAgent.Env.Policy

  defp ctx(rules \\ %{}) do
    %{
      workspace_root: "/srv/foreman/envs/e1/workspace",
      secrets_dir: "/run/foreman/envs/e1",
      protected: ["/run/foreman", "/var/lib/foreman-agent", "/srv/foreman/envs"],
      rules: Map.merge(Policy.default_rules(), rules)
    }
  end

  defp compose(svc), do: %{"name" => "pinch-1", "services" => %{"app" => svc}}

  defp reserving(devices),
    do: compose(%{"deploy" => %{"resources" => %{"reservations" => %{"devices" => devices}}}})

  # pinch's reservation: NVENC and Whisper.
  @pinch %{"driver" => "nvidia", "count" => -1, "capabilities" => ["gpu", "video", "utility"]}

  describe "an NVIDIA GPU reservation" do
    test "is refused by default under the gpu rule, saying how to allow it" do
      assert {:error, [message]} = Policy.check(reserving([@pinch]), %{}, ctx())
      assert message =~ "service 'app' reserves NVIDIA GPUs"
      assert message =~ "FOREMAN_POLICY=gpu=allow"
    end

    test "is allowed by gpu=allow and warned about by gpu=warn" do
      assert {:ok, []} = Policy.check(reserving([@pinch]), %{}, ctx(%{gpu: :allow}))
      assert {:ok, [message]} = Policy.check(reserving([@pinch]), %{}, ctx(%{gpu: :warn}))
      assert message =~ "GPUs"
    end

    test "isn't allowed by devices=allow alone" do
      assert {:error, [message]} = Policy.check(reserving([@pinch]), %{}, ctx(%{devices: :allow}))
      assert message =~ "gpu=allow"
    end

    test "may pick GPUs by index or UUID, or by count" do
      for entry <- [
            %{"driver" => "nvidia", "device_ids" => ["0", "1"], "capabilities" => ["compute"]},
            %{
              "driver" => "nvidia",
              "device_ids" => ["GPU-3b7f2c1e-9a0d-4c1f-8f5e-2d7a9b0c1e2f"],
              "capabilities" => ["gpu", "compute", "utility"]
            },
            %{"driver" => "nvidia", "count" => 2, "capabilities" => ["gpu", "compat32", "video"]},
            %{"driver" => "nvidia", "count" => "all", "capabilities" => ["nvidia", "compute"]}
          ] do
        assert {:ok, []} = Policy.check(reserving([entry]), %{}, ctx(%{gpu: :allow})),
               "expected #{inspect(entry)} to be a GPU reservation"
      end
    end
  end

  describe "the gpus key" do
    test "is reviewed: it's under the gpu rule, not compose_keys" do
      assert Policy.known_service_key?("gpus")

      config = compose(%{"gpus" => [%{"driver" => "nvidia", "capabilities" => ["compute"]}]})

      assert {:error, [message]} = Policy.check(config, %{}, ctx())
      assert message =~ "gpu=allow"
      assert {:ok, []} = Policy.check(config, %{}, ctx(%{gpu: :allow}))
    end

    test "gpus: all leaves the driver and its capabilities to the image, so it's a host device" do
      config = compose(%{"gpus" => [%{"count" => -1}]})

      assert {:error, [message]} = Policy.check(config, %{}, ctx(%{gpu: :allow}))
      assert message =~ "driver: nvidia"
      assert {:ok, []} = Policy.check(config, %{}, ctx(%{devices: :allow}))
    end
  end

  describe "reservations that stay under the devices rule" do
    # Each is something gpu=allow wasn't meant to grant: another driver
    # (CDI names any device), the display, options the review hasn't
    # covered, or a request that lets the image pick its capabilities.
    @not_gpus [
      {"another driver", %{"driver" => "cdi", "device_ids" => ["vendor.com/disk=sda"]}},
      {"no driver", %{"capabilities" => ["gpu", "compute"]}},
      {"graphics", %{"driver" => "nvidia", "capabilities" => ["gpu", "graphics"]}},
      {"display", %{"driver" => "nvidia", "capabilities" => ["gpu", "compute", "display"]}},
      {"an unknown capability", %{"driver" => "nvidia", "capabilities" => ["gpu", "everything"]}},
      {"no driver capabilities",
       %{"driver" => "nvidia", "count" => -1, "capabilities" => ["gpu"]}},
      {"options",
       %{"driver" => "nvidia", "capabilities" => ["compute"], "options" => %{"x" => "y"}}},
      {"a CDI device id",
       %{
         "driver" => "nvidia",
         "device_ids" => ["nvidia.com/gpu=all"],
         "capabilities" => ["compute"]
       }},
      {"a path for a device id",
       %{"driver" => "nvidia", "device_ids" => ["0/../sda"], "capabilities" => ["compute"]}},
      {"a huge count",
       %{"driver" => "nvidia", "count" => 1_000_000_000_000, "capabilities" => ["compute"]}},
      {"both count and device ids",
       %{"driver" => "nvidia", "count" => 1, "device_ids" => ["0"], "capabilities" => ["compute"]}},
      {"capabilities that aren't a list", %{"driver" => "nvidia", "capabilities" => "compute"}},
      {"something that isn't a map", "nvidia"}
    ]

    for {name, entry} <- @not_gpus do
      @entry entry
      test "#{name}" do
        assert {:error, [message]} = Policy.check(reserving([@entry]), %{}, ctx(%{gpu: :allow}))
        assert message =~ "host devices"
        assert {:ok, []} = Policy.check(reserving([@entry]), %{}, ctx(%{devices: :allow}))
      end
    end

    test "a GPU next to something else: only the something else is refused" do
      other = %{"driver" => "cdi", "device_ids" => ["vendor.com/disk=sda"]}

      assert {:error, [message]} =
               Policy.check(reserving([@pinch, other]), %{}, ctx(%{gpu: :allow}))

      assert message =~ "vendor.com/disk=sda"
    end
  end

  test "gpu=allow doesn't open devices mappings or cgroup rules" do
    for svc <- [%{"devices" => ["/dev/sda:/dev/sda"]}, %{"device_cgroup_rules" => ["c 1:* rmw"]}] do
      assert {:error, [message]} = Policy.check(compose(svc), %{}, ctx(%{gpu: :allow}))
      assert message =~ "host device"
    end
  end

  test "the nvidia runtime is a host device even when unreviewed keys are allowed" do
    config = compose(%{"runtime" => "nvidia"})

    assert {:error, [message]} =
             Policy.check(config, %{}, ctx(%{compose_keys: :allow, gpu: :allow}))

    assert message =~ "nvidia runtime"

    assert {:ok, []} = Policy.check(config, %{}, ctx(%{compose_keys: :allow, devices: :allow}))
  end

  describe "the box's Docker" do
    test "runc as the default runtime is fine" do
      assert {:ok, []} = Policy.check_docker(%{"DefaultRuntime" => "runc"}, ctx())
    end

    # With the nvidia runtime as the default, an image that sets
    # NVIDIA_VISIBLE_DEVICES (CUDA images do) gets GPUs with no
    # reservation, and NVIDIA_DRIVER_CAPABILITIES picks what comes with
    # them, the display included.
    test "nvidia as the default runtime is a host device for every environment" do
      info = %{"DefaultRuntime" => "nvidia"}

      assert {:error, [message]} = Policy.check_docker(info, ctx(%{gpu: :allow}))
      assert message =~ "default runtime"
      assert message =~ "runc"
      assert {:ok, []} = Policy.check_docker(info, ctx(%{devices: :allow}))
    end

    test "so is a default runtime that's NVIDIA's under another name" do
      info = %{
        "DefaultRuntime" => "gpu",
        "Runtimes" => %{"gpu" => %{"path" => "/usr/bin/nvidia-container-runtime"}}
      }

      assert {:error, [_]} = Policy.check_docker(info, ctx())
    end
  end
end
