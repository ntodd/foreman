defmodule Foreman.ActivityTest do
  use Foreman.DataCase
  use Oban.Testing, repo: Foreman.Repo

  alias Foreman.{Activity, Boxes, Operations, Scope}
  alias Foreman.Jobs.BoxOfflineNotice

  setup do
    owner = user_fixture()
    env = environment_fixture(user: owner, slug: "storefront-1")
    %{owner: owner, env: env}
  end

  defp op(env, action, attrs \\ %{}) do
    Operations.create!(
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          environment_id: env.id,
          box_id: env.box_id,
          action: action,
          command: "env." <> action,
          status: "running",
          args: %{}
        },
        attrs
      )
    )
  end

  describe "a finished environment operation" do
    test "goes to the environment's owner", %{owner: owner, env: env} do
      Activity.subscribe(Scope.for_user(owner))
      op = op(env, "rebuild")
      {:ok, _} = Operations.finish(op.id, "ok", %{}, nil)

      assert_receive {:activity,
                      %Activity{
                        kind: :operation,
                        action: "rebuild",
                        status: "succeeded",
                        subject: "storefront-1",
                        env_id: env_id
                      }}

      assert env_id == env.id
    end

    test "goes to admins, once", %{env: env} do
      Activity.subscribe(Scope.for_user(user_fixture(role: "admin")))
      op = op(env, "create")
      {:ok, _} = Operations.finish(op.id, "error", %{}, "devcontainer up failed")

      assert_receive {:activity, %Activity{status: "failed", error: "devcontainer up failed"}}
      refute_receive {:activity, _}
    end

    test "doesn't go to anyone else", %{env: env} do
      Activity.subscribe(Scope.for_user(user_fixture()))
      op = op(env, "stop")
      {:ok, _} = Operations.finish(op.id, "ok", %{}, nil)

      refute_receive {:activity, _}
    end

    test "is only the lifecycle: not secrets, git status or logs", %{owner: owner, env: env} do
      Activity.subscribe(Scope.for_user(owner))

      for action <- ~w(secrets_write git_status logs) do
        op = op(env, action)
        {:ok, _} = Operations.finish(op.id, "ok", %{}, nil)
      end

      refute_receive {:activity, _}
    end

    test "isn't news when someone cancelled it", %{owner: owner, env: env} do
      Activity.subscribe(Scope.for_user(owner))
      op = op(env, "rebuild")
      {:ok, _} = Operations.finish(op.id, "error", %{}, "cancelled")

      refute_receive {:activity, _}
    end
  end

  describe "a box" do
    setup %{owner: owner} do
      box = box_fixture(owner_user_id: owner.id)
      Activity.subscribe(Scope.for_user(owner))
      %{box: box}
    end

    defp join(box),
      do:
        Boxes.agent_joined(Boxes.get_box!(box.id), %{
          agent_version: "0.4.5",
          protocol_version: 1,
          hostname: "dev",
          os: "linux",
          arch: "x86_64",
          policy: %{}
        })

    defp seen(box, seconds_ago) do
      at = DateTime.add(DateTime.utc_now(), -seconds_ago)
      box |> Ecto.Changeset.change(last_seen_at: at) |> Repo.update!()
    end

    test "joining for the first time is news", %{box: box} do
      join(box)
      assert_receive {:activity, %Activity{kind: :box_joined, box_id: id}}
      assert id == box.id
    end

    test "a quick reconnect isn't, and coming back after a while is", %{box: box} do
      seen(box, 5)
      join(box)
      refute_receive {:activity, _}

      seen(box, 120)
      join(box)
      assert_receive {:activity, %Activity{kind: :box_online}}
    end

    test "going offline is news only if it stays offline", %{box: box} do
      seen(box, 0)
      Boxes.agent_left(box.id)
      assert_enqueued(worker: BoxOfflineNotice, args: %{"box_id" => box.id})

      [job] = all_enqueued(worker: BoxOfflineNotice)
      assert :ok = perform_job(BoxOfflineNotice, job.args)
      assert_receive {:activity, %Activity{kind: :box_offline}}

      # Back before the notice ran.
      Boxes.agent_left(box.id)
      [_, job] = all_enqueued(worker: BoxOfflineNotice)
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
      assert :ok = perform_job(BoxOfflineNotice, job.args)
      refute_receive {:activity, _}
    end

    test "a finished agent update is news", %{box: box} do
      op =
        Operations.create!(%{
          id: Ecto.UUID.generate(),
          box_id: box.id,
          action: "agent.update",
          command: "agent.update",
          status: "dispatched",
          args: %{"version" => "0.4.5"}
        })

      {:ok, _} = Operations.finish(op.id, "ok", %{}, nil)

      assert_receive {:activity,
                      %Activity{kind: :operation, action: "agent.update", version: "0.4.5"}}
    end

    test "is news only to people who can see it", %{box: box} do
      refute Activity.visible?(
               %Activity{kind: :box_online, box: box},
               user_fixture()
             )

      assert Activity.visible?(
               %Activity{kind: :box_online, box: box},
               user_fixture(role: "admin")
             )
    end
  end
end
