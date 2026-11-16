defmodule Foreman.PrebuildsTest do
  @moduledoc """
  Prebuilds: a box builds an environment's disk for a repo's default
  branch once, and new environments of that repo on that box start from
  it.
  """
  use Foreman.DataCase

  import Mox

  alias Foreman.{Agents, Environments, Prebuilds, Scope}
  alias Foreman.GitHub.ClientMock
  alias Foreman.Prebuilds.Prebuild
  alias ForemanProtocol.{Command, Event}

  setup :verify_on_exit!

  setup do
    admin = user_fixture(role: "admin")
    box = box_fixture(owner_user_id: admin.id, vm: %{"ready" => true})
    repo = repo_fixture()
    %{admin: admin, scope: Scope.for_user(admin), box: box, repo: repo}
  end

  defp online(box), do: {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

  defp report(box, op_id, payload) do
    {:ok, ev} = Event.new("op.result", Map.put(payload, :op_id, op_id))
    :ok = Agents.handle_event(box.id, ev)
  end

  defp prebuild_fixture(repo, box, attrs) do
    %Prebuild{
      repo_id: repo.id,
      box_id: box.id,
      branch: "main",
      config_path: repo.devcontainer_path,
      status: "ready",
      built_at: DateTime.utc_now()
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  describe "building one" do
    setup do
      Application.put_env(:foreman, :github_app, %{
        app_id: "1",
        client_id: "Iv1.x",
        client_secret: "s",
        private_key: "k"
      })

      on_exit(fn -> Application.delete_env(:foreman, :github_app) end)
    end

    test "sends the box the repo's default branch with a read-only token", ctx do
      online(ctx.box)
      installation = ctx.repo.owner.installation_id
      name = ctx.repo.name

      expect(ClientMock, :repo_read_token, fn _app, ^installation, [^name] ->
        {:ok, "ghs_readonly"}
      end)

      assert {:ok, %Prebuild{status: "building"} = prebuild} =
               Prebuilds.build(ctx.scope, ctx.repo, ctx.box)

      assert_receive {:dispatch, %Command{type: "box.prebuild", payload: p} = cmd}
      assert p.prebuild_id == prebuild.id
      assert p.repo == ctx.repo.full_name
      assert p.branch == "main"
      assert p.config_path == ctx.repo.devcontainer_path
      assert p.files == %{"github-token" => "ghs_readonly"}

      op = Foreman.Operations.get(cmd.op_id)
      assert op.action == "box.prebuild"
      assert op.box_id == ctx.box.id
      refute inspect(op.args) =~ "ghs_readonly"
      assert Repo.reload!(prebuild).op_id == cmd.op_id
    end

    test "without a token from GitHub, it builds anyway (a public repo still clones)", ctx do
      online(ctx.box)
      expect(ClientMock, :repo_read_token, fn _, _, _ -> {:error, :boom} end)

      assert {:ok, _} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
      assert_receive {:dispatch, %Command{type: "box.prebuild", payload: p}}
      assert p.files == %{}
    end
  end

  test "only an admin builds one", ctx do
    online(ctx.box)
    member = Scope.for_user(user_fixture())
    assert {:error, :unauthorized} = Prebuilds.build(member, ctx.repo, ctx.box)
    refute_receive {:dispatch, _}
  end

  test "an offline box can't", ctx do
    assert {:error, "The box is offline."} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert Repo.all(Prebuild) == []
  end

  test "a box that can't run environments can't", ctx do
    box = box_fixture(vm: %{"ready" => false, "reason" => "this box has no /dev/kvm"})
    online(box)

    assert {:error, "#{box.name} can't run environments: this box has no /dev/kvm"} ==
             Prebuilds.build(ctx.scope, ctx.repo, box)
  end

  test "a repo without a devcontainer can't", ctx do
    online(ctx.box)
    repo = repo_fixture(devcontainer_path: nil)
    assert {:error, "The repo has no devcontainer."} = Prebuilds.build(ctx.scope, repo, ctx.box)
  end

  test "one that's building isn't started twice", ctx do
    online(ctx.box)
    assert {:ok, _} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)

    assert {:error, "A prebuild is already building on this box."} =
             Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
  end

  test "the box's result makes it ready, and the one it replaces goes", ctx do
    online(ctx.box)
    old = prebuild_fixture(ctx.repo, ctx.box, %{})
    {:ok, prebuild} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}

    report(ctx.box, cmd.op_id, %{
      status: "ok",
      result: %{"prebuild_id" => prebuild.id, "size_mb" => 1234}
    })

    assert %Prebuild{status: "ready", size_mb: 1234, built_at: %DateTime{}} =
             Repo.reload!(prebuild)

    refute Repo.get(Prebuild, old.id)
    assert_receive {:dispatch, %Command{type: "box.prebuild.delete", payload: payload}}
    assert payload.prebuild_id == old.id
  end

  test "a build that fails says why, and keeps the one before", ctx do
    online(ctx.box)
    old = prebuild_fixture(ctx.repo, ctx.box, %{})
    {:ok, prebuild} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}

    report(ctx.box, cmd.op_id, %{status: "error", error: "devcontainer up failed"})

    assert %Prebuild{status: "failed", error: "devcontainer up failed"} = Repo.reload!(prebuild)
    assert Repo.get(Prebuild, old.id)
    refute_receive {:dispatch, %Command{type: "box.prebuild.delete"}}
  end

  test "a build that never reports back fails, after longer than other box commands", ctx do
    online(ctx.box)
    {:ok, prebuild} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}
    op = Foreman.Operations.get(cmd.op_id)

    dispatched = fn minutes_ago ->
      op
      |> Ecto.Changeset.change(dispatched_at: DateTime.add(DateTime.utc_now(), -minutes_ago * 60))
      |> Repo.update!()

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
    end

    dispatched.(60)
    assert %Prebuild{status: "building"} = Repo.reload!(prebuild)

    dispatched.(6 * 60)
    assert %Prebuild{status: "failed", error: "no result from the agent"} = Repo.reload!(prebuild)
  end

  test "deleting one takes it off the box", ctx do
    online(ctx.box)
    prebuild = prebuild_fixture(ctx.repo, ctx.box, %{})

    assert :ok = Prebuilds.delete(ctx.scope, prebuild)
    assert_receive {:dispatch, %Command{type: "box.prebuild.delete", payload: %{prebuild_id: id}}}
    assert id == prebuild.id
    refute Repo.get(Prebuild, prebuild.id)
  end

  test "deleting one on an offline box waits for the box", ctx do
    prebuild = prebuild_fixture(ctx.repo, ctx.box, %{})
    assert {:error, "The box is offline."} = Prebuilds.delete(ctx.scope, prebuild)
    assert Repo.get(Prebuild, prebuild.id)
  end

  test "lists the latest on each box for a repo", ctx do
    other = box_fixture(vm: %{"ready" => true})
    prebuild_fixture(ctx.repo, ctx.box, %{built_at: ~U[2026-11-01 00:00:00.000000Z]})
    newer = prebuild_fixture(ctx.repo, ctx.box, %{status: "building", built_at: nil})
    on_other = prebuild_fixture(ctx.repo, other, %{})

    by_box = Prebuilds.latest_by_box(ctx.repo)
    assert by_box[ctx.box.id].id == newer.id
    assert by_box[other.id].id == on_other.id
  end

  describe "a new environment" do
    test "on the box starts from its ready prebuild", ctx do
      online(ctx.box)
      prebuild = prebuild_fixture(ctx.repo, ctx.box, %{})

      assert {:ok, _env} =
               Environments.create_environment(ctx.scope, %{
                 "repo_id" => ctx.repo.id,
                 "box_id" => ctx.box.id
               })

      assert_receive {:dispatch, %Command{type: "env.create", payload: p}}
      assert p.prebuild_id == prebuild.id
    end

    test "of another branch, or on a box without one, starts from scratch", ctx do
      online(ctx.box)
      prebuild_fixture(ctx.repo, ctx.box, %{branch: "develop"})
      prebuild_fixture(ctx.repo, ctx.box, %{status: "building", built_at: nil})

      assert {:ok, _env} =
               Environments.create_environment(ctx.scope, %{
                 "repo_id" => ctx.repo.id,
                 "box_id" => ctx.box.id
               })

      assert_receive {:dispatch, %Command{type: "env.create", payload: p}}
      refute Map.has_key?(p, :prebuild_id)
    end
  end
end
