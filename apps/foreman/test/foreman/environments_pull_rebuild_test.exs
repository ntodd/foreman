defmodule Foreman.EnvironmentsPullRebuildTest do
  @moduledoc "Pull and rebuild: fast-forward the clone to its branch, then rebuild."
  use Foreman.DataCase

  alias Foreman.{Agents, Environments, Scope}
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id)
    box = box |> Ecto.Changeset.change(protocol_version: 3) |> Repo.update!()
    env = environment_fixture(user: user, box: box, branch: "feature/x")
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, box: box, env: env, scope: Scope.for_user(user)}
  end

  defp report(box, cmd, payload) do
    {:ok, ev} = Event.new("op.result", Map.put(payload, :op_id, cmd.op_id))
    :ok = Agents.handle_event(box.id, ev)
  end

  test "is sent as a rebuild that pulls first", ctx do
    assert {:ok, %{action: "pull_rebuild"}} = Environments.pull_rebuild(ctx.scope, ctx.env)

    assert_receive {:dispatch, %Command{type: "env.rebuild", payload: payload}}
    assert payload.pull == true
    assert payload.branch == "feature/x"
    assert Repo.reload!(ctx.env).observed_state == "creating"
  end

  test "a plain rebuild doesn't pull", ctx do
    {:ok, _} = Environments.rebuild(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.rebuild", payload: payload}}
    refute Map.has_key?(payload, :pull)
  end

  test "comes back up like a rebuild", ctx do
    {:ok, _} = Environments.pull_rebuild(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}

    report(ctx.box, cmd, %{status: "ok", result: %{"remote_user" => "vscode"}})

    env = Repo.reload!(ctx.env)
    assert env.observed_state == "running"
    assert env.remote_user == "vscode"
    assert env.status_message == nil
  end

  test "a refused pull leaves the environment running, and says why", ctx do
    {:ok, _} = Environments.pull_rebuild(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}

    report(ctx.box, cmd, %{
      status: "error",
      error: "4 changed files in the workspace; commit or stash them first",
      result: %{"pull_failed" => true}
    })

    env = Repo.reload!(ctx.env)
    assert env.observed_state == "running"
    assert env.desired_state == "running"

    assert env.status_message ==
             "Didn't pull: 4 changed files in the workspace; commit or stash them first"
  end

  test "a rebuild that fails after the pull is an error like any other", ctx do
    {:ok, _} = Environments.pull_rebuild(ctx.scope, ctx.env)
    assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}

    report(ctx.box, cmd, %{status: "error", error: "devcontainer up failed: build failed"})

    env = Repo.reload!(ctx.env)
    assert env.observed_state == "error"
    assert env.status_message == "devcontainer up failed: build failed"
  end

  test "an older agent can't pull", ctx do
    ctx.box |> Ecto.Changeset.change(protocol_version: 2) |> Repo.update!()

    assert {:error, message} = Environments.pull_rebuild(ctx.scope, ctx.env)
    assert message =~ "update its agent"
    refute_receive {:dispatch, _}
  end

  test "only the owner or an admin can pull", ctx do
    other = Scope.for_user(user_fixture())
    assert {:error, :unauthorized} = Environments.pull_rebuild(other, ctx.env)
  end
end
