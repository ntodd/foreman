defmodule ForemanWeb.AddBoxLiveTest do
  @moduledoc """
  "Add a box": one join token, and a way in for each kind of machine. A
  Linux machine runs the install script; a Mac or a Linux machine with
  KVM runs the box as a Flatcar VM with a launcher; bare metal (or any
  other hypervisor) boots Flatcar with the downloaded first-boot config.
  """
  use ForemanWeb.ConnCase

  import Mox

  alias Foreman.Tailscale.ClientMock

  setup :register_and_log_in_admin
  setup :set_mox_global

  defp add_box(conn, attrs \\ %{}) do
    {:ok, view, _html} = live(conn, ~p"/boxes")

    view
    |> form("#join-token-form", box: Map.merge(%{box_name: "studio"}, attrs))
    |> render_submit()

    view
  end

  defp token(view) do
    [token] = Regex.run(~r/fj_[A-Za-z0-9_-]+/, render(view))
    token
  end

  defp ignition(view, arch) do
    href = view |> element("#ignition-#{arch}") |> render() |> attr("href")
    "data:application/json;base64," <> data = href
    data |> Base.decode64!() |> JSON.decode!()
  end

  defp contents(config, path) do
    case Enum.find(config["storage"]["files"], &(&1["path"] == path)) do
      nil -> nil
      %{"contents" => %{"source" => "data:;base64," <> data}} -> Base.decode64!(data)
    end
  end

  defp attr(html, name) do
    [value] = Regex.run(~r/#{name}="([^"]+)"/, html, capture: :all_but_first)
    String.replace(value, "&amp;", "&")
  end

  test "a Linux machine gets the install command first", %{conn: conn} do
    view = add_box(conn)
    assert has_element?(view, "#install-command", "/agent/install.sh | sudo sh -s -- --token fj_")
  end

  test "a Mac runs the box as a VM with the Mac launcher, no sudo", %{conn: conn} do
    view = add_box(conn)
    view |> element("#join-kinds button", "Mac") |> render_click()

    assert has_element?(
             view,
             "#install-command",
             "/agent/mac.sh | sh -s -- --token #{token(view)}"
           )

    refute render(element(view, "#install-command")) =~ "sudo"
  end

  test "a Linux machine with KVM can run it as a VM too", %{conn: conn} do
    view = add_box(conn)
    view |> element("#join-kinds button", "Linux VM") |> render_click()
    assert has_element?(view, "#install-command", "/agent/vm.sh | sudo sh -s -- --token fj_")
  end

  test "bare metal gets a first-boot config to download, for each architecture", %{conn: conn} do
    view = add_box(conn)
    raw = token(view)
    view |> element("#join-kinds button", "Flatcar") |> render_click()

    for arch <- ["amd64", "arm64"] do
      link = view |> element("#ignition-#{arch}") |> render()
      assert attr(link, "download") == "studio-#{arch}.ign"

      config = ignition(view, arch)
      assert config["ignition"]["version"] == "3.4.0"
      assert contents(config, "/etc/foreman-box/provision.env") =~ raw
    end

    assert has_element?(view, "#add-box", "flatcar-install")
  end

  describe "the box's tailnet key" do
    setup do
      Application.put_env(:foreman, :tailscale, %{
        client_id: "c",
        client_secret: "s",
        tailnet: "-",
        tags: []
      })

      on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)
    end

    test "is minted once Flatcar is picked, and says which tags it has", %{conn: conn} do
      expect(ClientMock, :create_auth_key, 1, fn _, %{tags: ["tag:foreman-box"]} ->
        {:ok, %{key: "tskey-auth-minted", id: "k1"}}
      end)

      view = add_box(conn)
      refute has_element?(view, "#join-token-form input[name='box[tailscale_auth_key]']")
      view |> element("#join-kinds button", "Flatcar") |> render_click()

      assert inspect(ignition(view, "amd64")) =~
               "tskey-auth-minted" |> Base.encode64() |> binary_part(0, 12)

      assert has_element?(view, "#add-box", "tag:foreman-box")
    end

    test "Tailscale refusing is shown, not a config that can't reach Foreman", %{conn: conn} do
      stub(ClientMock, :create_auth_key, fn _, _ ->
        {:error, {:http, 400, "requested tags are invalid"}}
      end)

      view = add_box(conn)
      view |> element("#join-kinds button", "Flatcar") |> render_click()

      refute has_element?(view, "#ignition-amd64")
      assert has_element?(view, "#add-box", "requested tags are invalid")
    end
  end

  test "without a Tailscale OAuth client, a key can be pasted with the token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/boxes")
    assert has_element?(view, "#join-token-form input[name='box[tailscale_auth_key]']")

    view =
      add_box(conn, %{tailscale_auth_key: "tskey-auth-pasted"})

    view |> element("#join-kinds button", "Flatcar") |> render_click()

    assert inspect(ignition(view, "arm64")) =~
             "tskey-auth-pasted" |> Base.encode64() |> binary_part(0, 12)
  end
end
