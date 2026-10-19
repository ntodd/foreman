defmodule Foreman.TailscaleTest do
  use Foreman.DataCase

  import Mox

  alias Foreman.Tailscale
  alias Foreman.Tailscale.ClientMock

  setup :verify_on_exit!

  setup do
    Application.put_env(:foreman, :tailscale, %{
      client_id: "c",
      client_secret: "s",
      tailnet: "-",
      tags: []
    })

    on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)
  end

  test "cleanup removes devices recorded for destroyed environments, and nothing else" do
    env = environment_fixture(slug: "storefront-1", tailscale_device_id: "nLive")

    environment_fixture(
      slug: "storefront-9",
      tailscale_device_id: "nGone",
      destroyed_at: DateTime.utc_now()
    )

    stub(ClientMock, :list_devices, fn _ ->
      {:ok,
       [
         %{
           "id" => "1",
           "nodeId" => "nLive",
           "hostname" => env.slug,
           "tags" => ["tag:foreman-env"]
         },
         %{
           "id" => "2",
           "nodeId" => "nGone",
           "hostname" => "storefront-9",
           "tags" => ["tag:foreman-env"]
         },
         %{"id" => "3", "hostname" => "storefront-7", "tags" => ["tag:foreman-env"]},
         %{"id" => "4", "hostname" => "monas-laptop", "tags" => []}
       ]}
    end)

    expect(ClientMock, :delete_device, fn _, "2" -> :ok end)
    assert {:ok, 1} = Tailscale.cleanup()
  end

  test "team deployments tag nodes per developer" do
    Application.put_env(:foreman, :slug_style, :team)
    on_exit(fn -> Application.put_env(:foreman, :slug_style, :personal) end)

    repo = repo_fixture(tailscale_tags: ["tag:staging-access"])
    user = user_fixture(login: "Mona")

    assert Tailscale.tags_for(repo, user) == [
             "tag:foreman-env",
             "tag:staging-access",
             "tag:foreman-mona"
           ]
  end
end
