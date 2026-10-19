defmodule Foreman.EnvironmentsFeatureVersionTest do
  @moduledoc """
  The Foreman feature an environment was built with, and whether its box
  now ships a newer one.
  """
  use Foreman.DataCase

  alias Foreman.{Agents, Boxes, Environments, Scope}
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, repo: repo, box: box, scope: Scope.for_user(user)}
  end

  defp succeed(box, cmd, result) do
    {:ok, ev} = Event.new("op.result", %{op_id: cmd.op_id, status: "ok", result: result})
    :ok = Agents.handle_event(box.id, ev)
  end

  defp restart_all(ctx, env, result) do
    {:ok, _} = Environments.restart(ctx.scope, env, :all)
    assert_receive {:dispatch, %Command{type: "env.restart"} = restart}
    succeed(ctx.box, restart, result)
    Repo.reload!(env)
  end

  defp env_at(ctx, version),
    do:
      environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box, feature_version: version)

  defp join(attrs) do
    {:ok, join} =
      ForemanProtocol.cast_join(
        Map.merge(
          %{
            "agent_version" => "0.4.0",
            "protocol_version" => ForemanProtocol.version(),
            "hostname" => "box-a",
            "os" => "linux",
            "arch" => "x86_64"
          },
          attrs
        )
      )

    join
  end

  describe "results" do
    test "an up result records the version the environment was built with", ctx do
      {:ok, env} =
        Environments.create_environment(ctx.scope, %{
          "repo_id" => ctx.repo.id,
          "box_id" => ctx.box.id
        })

      assert_receive {:dispatch, %Command{type: "env.create"} = create}
      succeed(ctx.box, create, %{"remote_user" => "vscode", "feature_version" => "1.1.0"})

      assert Repo.reload!(env).feature_version == "1.1.0"
    end

    test "a restart result records it too", ctx do
      env = env_at(ctx, "1.0.0")

      env = restart_all(ctx, env, %{"restarted" => "all", "feature_version" => "1.1.0"})
      assert env.feature_version == "1.1.0"
    end

    # An older agent can rebuild it with an older feature without saying so.
    test "a result from an agent that doesn't report it leaves the version unknown", ctx do
      env = env_at(ctx, "1.2.0")

      {:ok, _} = Environments.rebuild(ctx.scope, env)
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = rebuild}
      succeed(ctx.box, rebuild, %{"remote_user" => "vscode"})

      assert Repo.reload!(env).feature_version == nil
    end

    test "a version that isn't one is unknown", ctx do
      env =
        restart_all(ctx, env_at(ctx, "1.0.0"), %{
          "restarted" => "all",
          "feature_version" => "the newest"
        })

      assert env.feature_version == nil
    end
  end

  describe "joining" do
    test "records the version the box's agent ships", ctx do
      assert Boxes.agent_joined(ctx.box, join(%{"feature_version" => "1.1.0"})).feature_version ==
               "1.1.0"
    end

    # The protocol's version format is looser than Version's.
    test "a version Elixir can't compare is unknown", ctx do
      box = Boxes.agent_joined(ctx.box, join(%{"feature_version" => "1.01.0"}))
      assert box.feature_version == nil
    end

    test "an agent that doesn't report it leaves it unknown", ctx do
      box = Boxes.agent_joined(ctx.box, join(%{"feature_version" => "1.1.0"}))
      assert Boxes.agent_joined(box, join(%{})).feature_version == nil
    end
  end

  describe "feature_update/1" do
    defp env_with(ctx, box_version, attrs) do
      box = ctx.box |> Ecto.Changeset.change(feature_version: box_version) |> Repo.update!()

      [user: ctx.user, repo: ctx.repo, box: box]
      |> Keyword.merge(attrs)
      |> environment_fixture()
      |> Repo.preload(:box)
    end

    test "says when the box ships a newer feature", ctx do
      env = env_with(ctx, "1.1.0", feature_version: "1.0.0")
      assert Environments.feature_update(env) == {:behind, "1.0.0", "1.1.0"}
    end

    test "says when the environment's version was never recorded", ctx do
      assert Environments.feature_update(env_with(ctx, "1.1.0", [])) == {:unknown, "1.1.0"}
    end

    test "is nil when the environment is up to date", ctx do
      assert Environments.feature_update(env_with(ctx, "1.1.0", feature_version: "1.1.0")) == nil
      assert Environments.feature_update(env_with(ctx, "1.1.0", feature_version: "1.2.0")) == nil
    end

    test "is nil when the box doesn't say what it ships", ctx do
      assert Environments.feature_update(env_with(ctx, nil, feature_version: "1.0.0")) == nil
    end

    test "is nil for a destroyed environment", ctx do
      env = env_with(ctx, "1.1.0", feature_version: "1.0.0", destroyed_at: DateTime.utc_now())
      assert Environments.feature_update(env) == nil
    end

    test "is nil for versions it can't compare", ctx do
      assert Environments.feature_update(env_with(ctx, "1.01.0", feature_version: "1.0.0")) == nil
    end

    test "is nil for an environment that has never come up", ctx do
      assert Environments.feature_update(env_with(ctx, "1.1.0", created_once: false)) == nil
    end
  end
end
