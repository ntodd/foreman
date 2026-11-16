defmodule ForemanWeb.RepoPrebuildsTest do
  @moduledoc "Admins build and delete a repo's prebuilds, per box, on the repo's page."
  use ForemanWeb.ConnCase

  alias Foreman.Prebuilds.Prebuild
  alias Foreman.Repo
  alias ForemanProtocol.{Command, Event}

  describe "an admin" do
    setup :register_and_log_in_admin

    setup do
      box = box_fixture(name: "pre-box", vm: %{"ready" => true})
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
      %{box: box, repo: repo_fixture()}
    end

    test "builds one on a box, and sees it ready when the box says so", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/repos/#{ctx.repo.id}")

      assert has_element?(view, "#prebuild-#{ctx.box.id}", "None")

      view |> element("#prebuild-#{ctx.box.id} button", "Build") |> render_click()

      assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}
      assert has_element?(view, "#prebuild-#{ctx.box.id}", "Building")

      {:ok, ev} =
        Event.new("op.result", %{op_id: cmd.op_id, status: "ok", result: %{"size_mb" => 2048}})

      :ok = Foreman.Agents.handle_event(ctx.box.id, ev)

      assert render(view) =~ "Ready"
      assert has_element?(view, "#prebuild-#{ctx.box.id}", "2.0 GB")
      assert has_element?(view, "#prebuild-#{ctx.box.id} button", "Rebuild")
    end

    test "sees why one failed, and deletes one", ctx do
      prebuild =
        Repo.insert!(%Prebuild{
          repo_id: ctx.repo.id,
          box_id: ctx.box.id,
          branch: "main",
          config_path: ctx.repo.devcontainer_path,
          status: "failed",
          error: "devcontainer up failed"
        })

      {:ok, view, _html} = live(ctx.conn, ~p"/repos/#{ctx.repo.id}")
      assert has_element?(view, "#prebuild-#{ctx.box.id}", "devcontainer up failed")

      view |> element("#prebuild-#{ctx.box.id} button", "Delete") |> render_click()

      assert_receive {:dispatch, %Command{type: "box.prebuild.delete"}}
      refute Repo.get(Prebuild, prebuild.id)
      assert has_element?(view, "#prebuild-#{ctx.box.id}", "None")
    end

    test "a box that can't run environments has no button", ctx do
      box = box_fixture(name: "no-kvm", vm: %{"ready" => false, "reason" => "no /dev/kvm"})
      {:ok, view, _html} = live(ctx.conn, ~p"/repos/#{ctx.repo.id}")

      assert has_element?(view, "#prebuild-#{box.id}", "can't run environments")
      refute has_element?(view, "#prebuild-#{box.id} button")
    end
  end

  describe "a member" do
    setup :register_and_log_in

    test "doesn't see prebuilds", %{conn: conn} do
      repo = repo_fixture()
      {:ok, view, _html} = live(conn, ~p"/repos/#{repo.id}")
      refute has_element?(view, "#prebuilds")
    end
  end
end
