defmodule Foreman.TailscaleCleanupTest do
  # Cleanup deletes tailnet devices, so it must never take one that belongs
  # to a live environment, to another deployment on the same tailnet, or to
  # anything Foreman didn't create.
  use Foreman.DataCase

  import Mox

  alias Foreman.Jobs.CleanupTailnet
  alias Foreman.Tailscale
  alias Foreman.Tailscale.ClientMock

  setup :verify_on_exit!

  defp configure(tags, deployment_tag \\ nil) do
    Application.put_env(:foreman, :tailscale, %{
      client_id: "c",
      client_secret: "s",
      tailnet: "-",
      tags: tags,
      deployment_tag: deployment_tag
    })

    on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)
  end

  defp devices(list), do: stub(ClientMock, :list_devices, fn _ -> {:ok, list} end)

  defp record_deletes do
    test_pid = self()

    stub(ClientMock, :delete_device, fn _, id ->
      send(test_pid, {:deleted, id})
      :ok
    end)
  end

  defp record_renames do
    test_pid = self()

    stub(ClientMock, :set_device_name, fn _, id, name ->
      send(test_pid, {:renamed, id, name})
      :ok
    end)
  end

  defp destroyed(attrs), do: environment_fixture([destroyed_at: DateTime.utc_now()] ++ attrs)

  # A control plane that isn't the deployment's (a test run against a real
  # tailnet) doesn't know the deployment's environments, so its sweep would
  # take them all.
  test "the hourly sweep can be turned off" do
    configure([], "tag:foreman-dev")
    Application.put_env(:foreman, :tailnet_sweep, false)
    on_exit(fn -> Application.delete_env(:foreman, :tailnet_sweep) end)

    devices([
      %{
        "id" => "n1",
        "hostname" => "someone-else-1",
        "tags" => ["tag:foreman-env", "tag:foreman-dev"]
      }
    ])

    record_deletes()

    assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})
    refute_received {:deleted, _}
  end

  # A delete can fail through a Tailscale outage; the hourly sweep only
  # covers destroyed environments, so the job's own retries have to last.
  test "cleanup retries for hours, not seconds" do
    backoffs =
      for attempt <- 1..(CleanupTailnet.__opts__()[:max_attempts] - 1),
          do: CleanupTailnet.backoff(%Oban.Job{attempt: attempt})

    assert Enum.sum(backoffs) >= 6 * 3600
  end

  test "every node gets tag:foreman-env, even when other tags are configured" do
    configure(["tag:dev"])
    repo = repo_fixture(tailscale_tags: ["tag:staging-access"])
    user = user_fixture()

    assert Tailscale.tags_for(repo, user) == ["tag:foreman-env", "tag:dev", "tag:staging-access"]
  end

  test "every node gets the deployment tag when one is configured" do
    configure(["tag:dev"], "tag:foreman-dev")
    repo = repo_fixture(tailscale_tags: [])
    user = user_fixture()

    assert Tailscale.tags_for(repo, user) == ["tag:foreman-env", "tag:dev", "tag:foreman-dev"]
  end

  describe "the sweep" do
    test "without a deployment tag, only removes devices recorded for destroyed environments" do
      configure([])
      live = environment_fixture(slug: "storefront-1", tailscale_device_id: "nLive")
      destroyed(slug: "storefront-9", tailscale_device_id: "nGone")

      devices([
        %{
          "id" => "1",
          "nodeId" => "nLive",
          "hostname" => live.slug,
          "tags" => ["tag:foreman-env"]
        },
        %{
          "id" => "9",
          "nodeId" => "nGone",
          "hostname" => "storefront-9",
          "tags" => ["tag:foreman-env"]
        },
        # Another deployment's environment on the same tailnet.
        %{
          "id" => "7",
          "nodeId" => "nOther",
          "hostname" => "storefront-7",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})

      assert_received {:deleted, "9"}
      refute_received {:deleted, _}
    end

    test "won't remove a recorded device that isn't named after its environment" do
      configure([])
      # The node ID comes from inside the repo's container.
      destroyed(slug: "storefront-9", tailscale_device_id: "nVictim")

      devices([
        %{
          "id" => "3",
          "nodeId" => "nVictim",
          "hostname" => "api-3",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})
      refute_received {:deleted, _}
    end

    test "with a deployment tag, won't remove a recorded device without it" do
      configure([], "tag:foreman-dev")
      destroyed(slug: "storefront-9", tailscale_device_id: "nTheirs")

      devices([
        %{
          "id" => "9",
          "nodeId" => "nTheirs",
          "hostname" => "storefront-9",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})
      refute_received {:deleted, _}
    end

    test "with a deployment tag, also removes this deployment's devices without a live environment" do
      configure(["tag:dev"], "tag:foreman-dev")
      env = environment_fixture(slug: "storefront-1")
      ours = ["tag:foreman-env", "tag:dev", "tag:foreman-dev"]

      devices([
        %{"id" => "env", "hostname" => env.slug, "tags" => ours},
        %{"id" => "stale", "hostname" => "storefront-9", "tags" => ours},
        %{
          "id" => "theirs",
          "hostname" => "storefront-8",
          "tags" => ["tag:foreman-env", "tag:dev"]
        },
        %{
          "id" => "laptop",
          "hostname" => "monas-laptop",
          "tags" => ["tag:dev", "tag:foreman-dev"]
        }
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})

      assert_received {:deleted, "stale"}
      refute_received {:deleted, _}
    end

    test "fails, so Oban retries, when a delete fails" do
      configure([])
      destroyed(slug: "gone-1", tailscale_device_id: "nGone")

      devices([
        %{"id" => "1", "nodeId" => "nGone", "hostname" => "gone-1", "tags" => ["tag:foreman-env"]}
      ])

      stub(ClientMock, :delete_device, fn _, _ -> {:error, {:http, 503, nil}} end)

      assert {:error, _} = CleanupTailnet.perform(%Oban.Job{args: %{}})
    end
  end

  describe "cleanup after a destroy" do
    test "removes the recorded device and not another deployment's with the same hostname" do
      configure([])

      devices([
        %{"id" => "1", "nodeId" => "nOurs", "hostname" => "api-1", "tags" => ["tag:foreman-env"]},
        %{
          "id" => "2",
          "nodeId" => "nTheirs",
          "hostname" => "api-1",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOurs"}
               })

      assert_received {:deleted, "1"}
      refute_received {:deleted, _}
    end

    test "won't remove a recorded device that isn't named after the environment" do
      configure([])

      devices([
        %{
          "id" => "3",
          "nodeId" => "nVictim",
          "hostname" => "api-3",
          "tags" => ["tag:foreman-env"]
        },
        %{"id" => "4", "nodeId" => "nLaptop", "hostname" => "api-1", "tags" => []}
      ])

      record_deletes()

      for id <- ["nVictim", "nLaptop"] do
        assert :ok =
                 CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "api-1", "device_id" => id}})
      end

      refute_received {:deleted, _}
    end

    # The ID comes from the repo's container, which could report another
    # deployment's node with the same hostname.
    test "with a deployment tag, won't remove a recorded device without it" do
      configure([], "tag:foreman-dev")

      devices([
        %{
          "id" => "2",
          "nodeId" => "nTheirs",
          "hostname" => "api-1",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nTheirs"}
               })

      refute_received {:deleted, _}
    end

    test "is done when the recorded device is already gone" do
      configure([])
      devices([])
      record_deletes()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOurs"}
               })

      refute_received {:deleted, _}
    end

    test "fails, so Oban retries, when a delete fails" do
      configure([])

      devices([
        %{"id" => "1", "nodeId" => "nOurs", "hostname" => "api-1", "tags" => ["tag:foreman-env"]}
      ])

      stub(ClientMock, :delete_device, fn _, _ -> {:error, :timeout} end)

      assert {:error, _} =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOurs"}
               })
    end

    test "with no recorded device and no deployment tag, removes nothing" do
      configure([])
      devices([%{"id" => "1", "hostname" => "api-1", "tags" => ["tag:foreman-env"]}])
      record_deletes()

      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "api-1"}})
      refute_received {:deleted, _}
    end

    test "with no recorded device, removes this deployment's devices with that hostname" do
      configure([], "tag:foreman-dev")

      devices([
        %{"id" => "someones-box", "hostname" => "api-1", "tags" => ["tag:foreman-dev"]},
        %{"id" => "theirs", "hostname" => "api-1", "tags" => ["tag:foreman-env"]},
        %{
          "id" => "old-env",
          "hostname" => "api-1",
          "tags" => ["tag:foreman-env", "tag:foreman-dev"]
        }
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "api-1"}})

      assert_received {:deleted, "old-env"}
      refute_received {:deleted, _}
    end

    test "with no recorded device, leaves it alone when a new environment has taken the slug" do
      configure([], "tag:foreman-dev")
      environment_fixture(slug: "storefront-2")

      devices([
        %{
          "id" => "new-node",
          "hostname" => "storefront-2",
          "tags" => ["tag:foreman-env", "tag:foreman-dev"]
        }
      ])

      record_deletes()

      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "storefront-2"}})
      refute_received {:deleted, _}
    end
  end

  # A recreated environment that lost its Tailscale state joins as a new
  # node, and Tailscale names it <slug>-1 while the old one is around.
  describe "cleanup after a replacement" do
    test "removes the old device and gives the new one the bare name" do
      configure([])
      environment_fixture(slug: "api-1", tailscale_device_id: "nNew")

      devices([
        %{
          "id" => "1",
          "nodeId" => "nOld",
          "hostname" => "api-1",
          "name" => "api-1.tail1234.ts.net",
          "tags" => ["tag:foreman-env"]
        },
        %{
          "id" => "2",
          "nodeId" => "nNew",
          "hostname" => "api-1",
          "name" => "api-1-1.tail1234.ts.net",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      record_renames()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOld", "replaced_by" => "nNew"}
               })

      assert_received {:deleted, "1"}
      refute_received {:deleted, _}
      assert_received {:renamed, "2", "api-1"}
    end

    test "leaves a new device that already has the bare name" do
      configure([])

      devices([
        %{
          "id" => "2",
          "nodeId" => "nNew",
          "hostname" => "api-1",
          "name" => "api-1.tail1234.ts.net",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      record_renames()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOld", "replaced_by" => "nNew"}
               })

      refute_received {:renamed, _, _}
    end

    test "won't rename a device that isn't named after the environment" do
      configure([])

      devices([
        %{
          "id" => "3",
          "nodeId" => "nVictim",
          "hostname" => "api-3",
          "name" => "api-3.tail1234.ts.net",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      record_renames()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOld", "replaced_by" => "nVictim"}
               })

      refute_received {:renamed, _, _}
    end

    # The name can be held by an old device another job is still removing.
    test "fails, so Oban retries, when the rename fails" do
      configure([])

      devices([
        %{
          "id" => "2",
          "nodeId" => "nNew",
          "hostname" => "api-1",
          "name" => "api-1-1.tail1234.ts.net",
          "tags" => ["tag:foreman-env"]
        }
      ])

      stub(ClientMock, :set_device_name, fn _, _, _ -> {:error, {:http, 409, "name taken"}} end)

      assert {:error, _} =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOld", "replaced_by" => "nNew"}
               })
    end

    test "with a deployment tag, won't touch devices without it" do
      configure([], "tag:foreman-dev")

      devices([
        %{"id" => "1", "nodeId" => "nOld", "hostname" => "api-1", "tags" => ["tag:foreman-env"]},
        %{
          "id" => "2",
          "nodeId" => "nNew",
          "hostname" => "api-1",
          "name" => "api-1-1.tail1234.ts.net",
          "tags" => ["tag:foreman-env"]
        }
      ])

      record_deletes()
      record_renames()

      assert :ok =
               CleanupTailnet.perform(%Oban.Job{
                 args: %{"slug" => "api-1", "device_id" => "nOld", "replaced_by" => "nNew"}
               })

      refute_received {:deleted, _}
      refute_received {:renamed, _, _}
    end
  end
end
