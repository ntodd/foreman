defmodule ForemanWeb.BoxAgentVersionTest do
  use ForemanWeb.ConnCase

  alias Foreman.Repo

  setup :register_and_log_in_admin

  setup %{user: user} do
    box = box_fixture(owner_user_id: user.id, name: "desktop")
    %{box: Repo.update!(Ecto.Changeset.change(box, agent_version: "0.1.0"))}
  end

  test "a box that isn't pinned follows the control plane", %{conn: conn, box: box} do
    {:ok, _view, html} = live(conn, ~p"/boxes/#{box.id}")
    assert html =~ "Follow this control plane"
  end

  @tag :tmp_dir
  test "the pin field says which version following means", %{conn: conn, box: box, tmp_dir: tmp} do
    {public, private} = ForemanProtocol.Auth.generate_keypair()
    Application.put_env(:foreman, :agent_release_public_key, Base.encode64(public))
    Application.put_env(:foreman, :agent_release_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:foreman, :agent_release_public_key)
      Application.delete_env(:foreman, :agent_release_dir)
    end)

    # Registered by hand, on an image that carries no agents.
    tarball = Path.join(tmp, "agent.tar.gz")
    File.write!(tarball, "release bytes")
    sha = :crypto.hash(:sha256, "release bytes") |> Base.encode16(case: :lower)
    sig = ForemanProtocol.Auth.sign_release("0.2.0", "linux-arm64", sha, private)
    {:ok, _} = Foreman.Agents.Releases.register("0.2.0", "linux-arm64", tarball, sig)
    box = Repo.update!(Ecto.Changeset.change(box, arch: "linux-arm64"))

    {:ok, _view, html} = live(conn, ~p"/boxes/#{box.id}")
    assert html =~ "Follow this control plane (0.2.0)"
  end

  test "a box on its way to another version says so", %{conn: conn, box: box} do
    box = Repo.update!(Ecto.Changeset.change(box, desired_agent_version: "0.2.0"))
    {:ok, _view, html} = live(conn, ~p"/boxes/#{box.id}")
    assert html =~ "agent 0.1.0, updating to 0.2.0"
  end

  test "an old failure isn't shown once the box is headed somewhere else", %{conn: conn, box: box} do
    box =
      Repo.update!(
        Ecto.Changeset.change(box, desired_agent_version: "0.3.0", failed_agent_version: "0.2.0")
      )

    {:ok, _view, html} = live(conn, ~p"/boxes/#{box.id}")
    refute html =~ "come up on this box twice"
    assert html =~ "agent 0.1.0, updating to 0.3.0"
  end

  test "a version that failed twice says so, and Retry sends it again", %{conn: conn, box: box} do
    box =
      Repo.update!(
        Ecto.Changeset.change(box, desired_agent_version: "0.2.0", failed_agent_version: "0.2.0")
      )

    {:ok, view, html} = live(conn, ~p"/boxes/#{box.id}")
    assert html =~ "Agent 0.2.0 didn&#39;t come up on this box twice"
    refute html =~ "updating to 0.2.0"

    view |> element("button", "Retry") |> render_click()
    assert Repo.reload!(box).failed_agent_version == nil
    refute render(view) =~ "come up on this box twice"
  end
end
