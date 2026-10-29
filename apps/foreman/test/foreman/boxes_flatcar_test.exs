defmodule Foreman.BoxesFlatcarTest do
  @moduledoc """
  A Flatcar box's first-boot config, for a join token: what the Mac and
  Linux launchers fetch, and what "Add a box" offers to download. With a
  Tailscale OAuth client, the control plane mints the box its own
  single-use key, once per token.
  """
  use Foreman.DataCase

  import Mox

  alias Foreman.{Boxes, Scope}
  alias Foreman.Tailscale.ClientMock

  setup :verify_on_exit!

  setup do
    admin = Scope.for_user(user_fixture(role: "admin"))
    %{admin: admin}
  end

  defp token(admin, attrs \\ %{}) do
    {:ok, raw} = Boxes.create_join_token(admin, Map.merge(%{"box_name" => "studio"}, attrs))
    raw
  end

  defp tailscale(config) do
    Application.put_env(
      :foreman,
      :tailscale,
      Map.merge(%{client_id: "c", client_secret: "s", tailnet: "-", tags: []}, config)
    )

    on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)
  end

  # Files are inline data: URLs, base64.
  defp contents(config, path) do
    case Enum.find(config["storage"]["files"], &(&1["path"] == path)) do
      nil -> nil
      %{"contents" => %{"source" => "data:;base64," <> data}} -> Base.decode64!(data)
    end
  end

  test "a join token's config enrolls a box of that name with this control plane", %{admin: admin} do
    raw = token(admin)
    assert {:ok, config, "studio"} = Boxes.flatcar_ignition(raw, %{"arch" => "amd64"})
    config = config |> JSON.encode!() |> JSON.decode!()

    env = contents(config, "/etc/foreman-box/provision.env")
    assert env =~ ~s(FOREMAN_URL="#{Foreman.Config.base_url()}")
    assert env =~ ~s(FOREMAN_JOIN_TOKEN="#{raw}")
    assert env =~ ~s(FOREMAN_BOX_NAME="studio")
    assert contents(config, "/etc/hostname") == "studio\n"
  end

  test "takes SSH keys for core", %{admin: admin} do
    key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeyForCore core@mac"

    assert {:ok, %{"passwd" => %{"users" => [%{"sshAuthorizedKeys" => [^key]}]}}, _} =
             Boxes.flatcar_ignition(token(admin), %{"arch" => "arm64", "ssh_keys" => [key]})

    # One per line, as a form sends them.
    assert {:ok, %{"passwd" => %{"users" => [%{"sshAuthorizedKeys" => [^key, ^key]}]}}, _} =
             Boxes.flatcar_ignition(token(admin), %{
               "arch" => "arm64",
               "ssh_keys" => "#{key}\n\n#{key}\n"
             })

    assert {:error, :bad_ssh_key} =
             Boxes.flatcar_ignition(token(admin), %{"arch" => "arm64", "ssh_keys" => ["nope"]})
  end

  test "a used, expired or unknown token gets nothing", %{admin: admin} do
    assert {:error, :invalid_token} = Boxes.flatcar_ignition("fj_nope", %{"arch" => "amd64"})

    expired = token(admin)

    Repo.update_all(Foreman.Boxes.JoinToken,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:error, :invalid_token} = Boxes.flatcar_ignition(expired, %{"arch" => "amd64"})

    used = token(admin, %{"box_name" => "used"})

    {:ok, _box} =
      Boxes.enroll(used, %{"public_key" => Base.encode64(:crypto.strong_rand_bytes(32))})

    assert {:error, :invalid_token} = Boxes.flatcar_ignition(used, %{"arch" => "amd64"})
  end

  test "an architecture Flatcar doesn't ship", %{admin: admin} do
    assert {:error, :bad_arch} = Boxes.flatcar_ignition(token(admin), %{"arch" => "riscv64"})
    assert {:error, :bad_arch} = Boxes.flatcar_ignition(token(admin), %{})
  end

  describe "with a Tailscale OAuth client" do
    test "mints the box a single-use key with the box tags, once per token", %{admin: admin} do
      tailscale(%{box_tags: ["tag:foreman-box", "tag:dev"]})
      raw = token(admin)

      expect(ClientMock, :create_auth_key, fn _creds, key ->
        assert key.tags == ["tag:foreman-box", "tag:dev"]
        assert key.description =~ "studio"
        {:ok, %{key: "tskey-auth-box", id: "k1"}}
      end)

      {:ok, first, _} = Boxes.flatcar_ignition(raw, %{"arch" => "amd64"})
      {:ok, again, _} = Boxes.flatcar_ignition(raw, %{"arch" => "arm64"})

      for config <- [first, again] do
        config = config |> JSON.encode!() |> JSON.decode!()
        assert contents(config, "/etc/foreman-box/tailscale-authkey") == "tskey-auth-box"
      end
    end

    test "tags boxes tag:foreman-box unless told otherwise", %{admin: admin} do
      tailscale(%{})

      expect(ClientMock, :create_auth_key, fn _creds, %{tags: tags} ->
        assert tags == ["tag:foreman-box"]
        {:ok, %{key: "tskey-auth-box", id: "k1"}}
      end)

      assert {:ok, _, _} = Boxes.flatcar_ignition(token(admin), %{"arch" => "amd64"})
    end

    test "a key Tailscale won't mint is an error, not a box that can't reach Foreman", %{
      admin: admin
    } do
      tailscale(%{})

      expect(ClientMock, :create_auth_key, fn _, _ ->
        {:error, {:http, 403, "tag not permitted"}}
      end)

      assert {:error, {:tailscale, _}} =
               Boxes.flatcar_ignition(token(admin), %{"arch" => "amd64"})
    end
  end

  describe "without one" do
    test "uses the key pasted when the token was made", %{admin: admin} do
      raw = token(admin, %{"tailscale_auth_key" => "tskey-auth-pasted"})
      {:ok, config, _} = Boxes.flatcar_ignition(raw, %{"arch" => "amd64"})
      config = config |> JSON.encode!() |> JSON.decode!()
      assert contents(config, "/etc/foreman-box/tailscale-authkey") == "tskey-auth-pasted"
    end

    test "leaves the tailnet out when there's no key at all", %{admin: admin} do
      {:ok, config, _} = Boxes.flatcar_ignition(token(admin), %{"arch" => "amd64"})
      config = config |> JSON.encode!() |> JSON.decode!()
      assert contents(config, "/etc/foreman-box/tailscale-authkey") == nil
    end

    test "refuses something pasted that isn't a Tailscale auth key", %{admin: admin} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Boxes.create_join_token(admin, %{
                 "box_name" => "x",
                 "tailscale_auth_key" => "hunter2"
               })

      assert %{tailscale_auth_key: [_]} = errors_on(cs)
    end
  end

  test "the pasted key is stored encrypted and never shown back", %{admin: admin} do
    token(admin, %{"tailscale_auth_key" => "tskey-auth-pasted"})
    [row] = Repo.all(Foreman.Boxes.JoinToken)
    assert row.tailscale_auth_key == "tskey-auth-pasted"
    refute inspect(row) =~ "tskey-auth-pasted"

    {:ok, %{rows: [[stored]]}} = Repo.query("SELECT tailscale_auth_key FROM join_tokens")
    refute stored =~ "tskey"
  end
end
