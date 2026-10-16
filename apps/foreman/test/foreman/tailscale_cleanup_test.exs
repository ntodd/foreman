defmodule Foreman.TailscaleCleanupTest do
  # Cleanup deletes tailnet devices, so it must never take one that belongs
  # to a live environment or to anything Foreman didn't create.
  use Foreman.DataCase

  import Mox

  alias Foreman.Jobs.CleanupTailnet
  alias Foreman.Tailscale
  alias Foreman.Tailscale.ClientMock

  setup :verify_on_exit!

  defp configure(tags) do
    Application.put_env(:foreman, :tailscale, %{
      client_id: "c",
      client_secret: "s",
      tailnet: "-",
      tags: tags
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

  # A control plane that isn't the deployment's (a test run against a real
  # tailnet) doesn't know the deployment's environments, so its sweep would
  # take them all.
  test "the hourly sweep can be turned off" do
    configure([])
    Application.put_env(:foreman, :tailnet_sweep, false)
    on_exit(fn -> Application.delete_env(:foreman, :tailnet_sweep) end)
    devices([%{"id" => "n1", "hostname" => "someone-else-1", "tags" => ["tag:foreman-env"]}])
    record_deletes()

    assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})
    refute_received {:deleted, _}
  end

  test "every node gets tag:foreman-env, even when other tags are configured" do
    configure(["tag:dev"])
    repo = repo_fixture(tailscale_tags: ["tag:staging-access"])
    user = user_fixture()

    assert Tailscale.tags_for(repo, user) == ["tag:foreman-env", "tag:dev", "tag:staging-access"]
  end

  describe "the sweep" do
    test "only removes devices carrying tag:foreman-env, whatever else is configured" do
      configure(["tag:foreman-env", "tag:dev"])
      env = environment_fixture(slug: "storefront-1")

      devices([
        %{"id" => "env", "hostname" => env.slug, "tags" => ["tag:foreman-env", "tag:dev"]},
        %{
          "id" => "stale",
          "hostname" => "storefront-9",
          "tags" => ["tag:foreman-env", "tag:dev"]
        },
        %{"id" => "laptop", "hostname" => "monas-laptop", "tags" => ["tag:dev"]}
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{}})

      assert_received {:deleted, "stale"}
      refute_received {:deleted, "laptop"}
      refute_received {:deleted, "env"}
    end

    test "fails, so Oban retries, when a delete fails" do
      configure([])
      devices([%{"id" => "stale", "hostname" => "gone-1", "tags" => ["tag:foreman-env"]}])
      stub(ClientMock, :delete_device, fn _, _ -> {:error, {:http, 503, nil}} end)

      assert {:error, _} = CleanupTailnet.perform(%Oban.Job{args: %{}})
    end
  end

  describe "cleanup after a destroy" do
    test "leaves the device alone when a new environment has taken the slug" do
      configure([])
      environment_fixture(slug: "storefront-2")

      devices([
        %{"id" => "new-node", "hostname" => "storefront-2", "tags" => ["tag:foreman-env"]}
      ])

      record_deletes()

      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "storefront-2"}})
      refute_received {:deleted, "new-node"}
    end

    test "only removes Foreman-tagged devices with that hostname" do
      configure([])

      devices([
        %{"id" => "someones-box", "hostname" => "api-1", "tags" => []},
        %{"id" => "old-env", "hostname" => "api-1", "tags" => ["tag:foreman-env"]}
      ])

      record_deletes()
      assert :ok = CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "api-1"}})

      assert_received {:deleted, "old-env"}
      refute_received {:deleted, "someones-box"}
    end

    test "fails, so Oban retries, when a delete fails" do
      configure([])
      devices([%{"id" => "old-env", "hostname" => "api-1", "tags" => ["tag:foreman-env"]}])
      stub(ClientMock, :delete_device, fn _, _ -> {:error, :timeout} end)

      assert {:error, _} = CleanupTailnet.perform(%Oban.Job{args: %{"slug" => "api-1"}})
    end
  end
end
