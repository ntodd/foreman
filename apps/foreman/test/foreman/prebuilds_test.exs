defmodule Foreman.PrebuildsTest do
  @moduledoc """
  Prebuilds: a box builds an environment's disk for a repo's default
  branch once, and new environments of that repo on that box start from
  it.
  """
  use Foreman.DataCase

  import Mox

  alias Foreman.{Agents, Environments, Operations, Prebuilds, Scope}
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

  defp github_configured(_ctx) do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:foreman, :github_app) end)
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
    setup :github_configured

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

    test "builds in a VM the size of the repo's environments", ctx do
      online(ctx.box)
      stub(ClientMock, :repo_read_token, fn _, _, _ -> {:ok, "ghs_readonly"} end)

      repo = repo_fixture(cpu_limit: 2.0, memory_limit_mb: 4096)
      assert {:ok, _} = Prebuilds.build(ctx.scope, repo, ctx.box)
      assert_receive {:dispatch, %Command{type: "box.prebuild", payload: p}}
      assert p.limits == %{cpus: 2.0, memory_mb: 4096}

      repo = repo_fixture(memory_limit_mb: 2048)
      assert {:ok, _} = Prebuilds.build(ctx.scope, repo, ctx.box)
      assert_receive {:dispatch, %Command{type: "box.prebuild", payload: p}}
      assert p.limits == %{memory_mb: 2048}
    end

    test "a build that raises before it's sent leaves nothing to block the next", ctx do
      online(ctx.box)
      expect(ClientMock, :repo_read_token, fn _, _, _ -> raise "GitHub went away" end)

      assert_raise RuntimeError, fn -> Prebuilds.build(ctx.scope, ctx.repo, ctx.box) end
      assert Repo.all(Prebuild) == []
      assert Repo.all(Foreman.Operations.Operation) == []

      expect(ClientMock, :repo_read_token, fn _, _, _ -> {:ok, "ghs_readonly"} end)
      assert {:ok, _} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    end
  end

  test "a branch the box would refuse is an error, and leaves nothing behind", ctx do
    online(ctx.box)
    repo = ctx.repo |> Ecto.Changeset.change(default_branch: "not a branch") |> Repo.update!()

    assert {:error, "Couldn't make the build's command: " <> _} =
             Prebuilds.build(ctx.scope, repo, ctx.box)

    assert Repo.all(Prebuild) == []
    assert Repo.all(Foreman.Operations.Operation) == []
    refute_receive {:dispatch, _}
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

  test "a build that finishes after its prebuild was forgotten is taken off the box", ctx do
    online(ctx.box)
    {:ok, prebuild} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}
    Repo.delete!(prebuild)

    report(ctx.box, cmd.op_id, %{status: "ok", result: %{"size_mb" => 10}})

    assert_receive {:dispatch, %Command{type: "box.prebuild.delete", payload: %{prebuild_id: id}}}
    assert id == prebuild.id
    refute Repo.get(Prebuild, prebuild.id)
  end

  test "a forgotten build that fails leaves nothing to delete", ctx do
    online(ctx.box)
    {:ok, prebuild} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}
    Repo.delete!(prebuild)

    report(ctx.box, cmd.op_id, %{status: "error", error: "devcontainer up failed"})
    refute_receive {:dispatch, %Command{type: "box.prebuild.delete"}}
  end

  # The deletes go out once the result that replaces them is recorded: one
  # sent from inside the transaction could reach the box before its
  # operation is visible, or delete a disk a rollback leaves marked ready.
  test "the one a build replaces isn't deleted if recording the result fails", ctx do
    online(ctx.box)
    old = prebuild_fixture(ctx.repo, ctx.box, %{})
    {:ok, prebuild} = Prebuilds.build(ctx.scope, ctx.repo, ctx.box)
    assert_receive {:dispatch, %Command{type: "box.prebuild"} = cmd}

    assert_raise RuntimeError, fn ->
      Operations.finish(cmd.op_id, "ok", %{}, nil, fn op ->
        Environments.record_result(op)
        raise "the transaction fails"
      end)
    end

    refute_receive {:dispatch, %Command{type: "box.prebuild.delete"}}
    assert Repo.get(Prebuild, old.id)
    assert %Prebuild{status: "building"} = Repo.reload!(prebuild)
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

  test "one that's building can't be deleted", ctx do
    online(ctx.box)
    prebuild = prebuild_fixture(ctx.repo, ctx.box, %{status: "building", built_at: nil})

    assert {:error, "It's still building; delete it once it's done."} =
             Prebuilds.delete(ctx.scope, prebuild)

    assert Repo.get(Prebuild, prebuild.id)
    refute_receive {:dispatch, _}
  end

  test "pruning a box names every prebuild the control plane knows there", ctx do
    online(ctx.box)
    ready = prebuild_fixture(ctx.repo, ctx.box, %{})
    failed = prebuild_fixture(ctx.repo, ctx.box, %{status: "failed", built_at: nil})
    building = prebuild_fixture(repo_fixture(), ctx.box, %{status: "building", built_at: nil})
    prebuild_fixture(ctx.repo, box_fixture(vm: %{"ready" => true}), %{})

    {:ok, op} = Agents.run_box_command(ctx.scope, ctx.box, "box.gc")

    assert_receive {:dispatch, %Command{type: "box.gc", payload: %{prebuilds: ids}}}
    assert Enum.sort(ids) == Enum.sort([ready.id, failed.id, building.id])
    assert op.args["prebuilds"] == ids
  end

  test "pruning a box without prebuilds says it should have none", ctx do
    online(ctx.box)
    {:ok, _} = Agents.run_box_command(ctx.scope, ctx.box, "box.gc")
    assert_receive {:dispatch, %Command{type: "box.gc", payload: %{prebuilds: []}}}
  end

  describe "on the repo's page" do
    defp at(minutes_ago), do: DateTime.add(DateTime.utc_now(), -minutes_ago * 60)

    test "each box has the one in use, then the latest attempt when it's another", ctx do
      other = box_fixture(vm: %{"ready" => true})
      in_use = prebuild_fixture(ctx.repo, ctx.box, %{inserted_at: at(60)})

      failed =
        prebuild_fixture(ctx.repo, ctx.box, %{status: "failed", built_at: nil, inserted_at: at(5)})

      on_other = prebuild_fixture(ctx.repo, other, %{})

      by_box = Prebuilds.by_box(ctx.repo)
      assert Enum.map(by_box[ctx.box.id], & &1.id) == [in_use.id, failed.id]
      assert Enum.map(by_box[other.id], & &1.id) == [on_other.id]
    end

    test "a ready one for an old branch or config is there, after the one in use", ctx do
      old_branch =
        prebuild_fixture(ctx.repo, ctx.box, %{branch: "master", inserted_at: at(90)})

      in_use = prebuild_fixture(ctx.repo, ctx.box, %{inserted_at: at(60)})

      old_config =
        prebuild_fixture(ctx.repo, ctx.box, %{
          config_path: ".devcontainer/old/devcontainer.json",
          inserted_at: at(30)
        })

      building =
        prebuild_fixture(ctx.repo, ctx.box, %{
          status: "building",
          built_at: nil,
          inserted_at: at(1)
        })

      assert Enum.map(Prebuilds.by_box(ctx.repo)[ctx.box.id], & &1.id) ==
               [in_use.id, old_config.id, old_branch.id, building.id]

      assert Prebuilds.unused_because(ctx.repo, in_use) == nil
      assert Prebuilds.unused_because(ctx.repo, old_branch) == {:branch, "master"}

      assert Prebuilds.unused_because(ctx.repo, old_config) ==
               {:config, ".devcontainer/old/devcontainer.json"}
    end
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

  # A prebuild holds the repo's content, cloned with the app's token, so an
  # environment starts from one only once the user's own token has shown
  # it can read everything the prebuild could.
  describe "a new environment, with GitHub" do
    setup :github_configured

    setup ctx do
      online(ctx.box)

      repo =
        ctx.repo
        |> Ecto.Changeset.change(extra_repos: ["shared-config"])
        |> Repo.update!()
        |> Repo.preload(:owner, force: true)

      %{repo: repo, prebuild: prebuild_fixture(repo, ctx.box, %{})}
    end

    defp create(ctx) do
      assert {:ok, _env} =
               Environments.create_environment(ctx.scope, %{
                 "repo_id" => ctx.repo.id,
                 "box_id" => ctx.box.id
               })

      assert_receive {:dispatch, %Command{type: "env.create", payload: p}}
      p
    end

    defp user_token(token) do
      expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
        {:ok, %{token: token, expires_at: nil}}
      end)
    end

    test "starts from the prebuild when the user can read the repo and its extra repos", ctx do
      user_token("ghu_scoped")
      names = [ctx.repo.full_name, "#{ctx.repo.owner.login}/shared-config"]

      expect(ClientMock, :get_repo, 2, fn "ghu_scoped", name ->
        assert name in names
        {:ok, %{"full_name" => name}}
      end)

      assert create(ctx).prebuild_id == ctx.prebuild.id
    end

    test "builds from scratch when the user can't read one of its extra repos", ctx do
      user_token("ghu_scoped")
      extra = "#{ctx.repo.owner.login}/shared-config"

      stub(ClientMock, :get_repo, fn
        "ghu_scoped", ^extra -> {:error, :not_found}
        "ghu_scoped", _ -> {:ok, %{}}
      end)

      p = create(ctx)
      refute Map.has_key?(p, :prebuild_id)
      assert p.files["github-token"] == "ghu_scoped"
    end

    test "builds from scratch when GitHub can't say", ctx do
      user_token("ghu_scoped")
      stub(ClientMock, :get_repo, fn _, _ -> {:error, {:http, 502, "Bad Gateway"}} end)

      refute Map.has_key?(create(ctx), :prebuild_id)
    end

    test "builds from scratch without a token for the user", ctx do
      expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
        {:error, {:http, 502, "Bad Gateway"}}
      end)

      refute Map.has_key?(create(ctx), :prebuild_id)
    end
  end
end
