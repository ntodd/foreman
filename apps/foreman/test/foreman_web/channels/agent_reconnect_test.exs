defmodule ForemanWeb.AgentReconnectTest do
  @moduledoc """
  What happens when an agent joins again: after a reboot, after a blip,
  and while an agent update is under way. Driven through the real channel.
  """
  use ForemanWeb.ChannelCase

  import Ecto.Query

  alias Foreman.{Agents, Boxes, Environments, Operations, Repo, Scope}
  alias ForemanProtocol.{Auth, Event}
  alias ForemanWeb.AgentSocket

  setup do
    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo, box: box)
    %{user: user, repo: repo, box: box, env: env, scope: Scope.for_user(user)}
  end

  defp join_box(box, overrides \\ %{}) do
    {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
    {:ok, _, socket} = subscribe_and_join(socket, "agent:#{box.id}", join_payload(overrides))
    socket
  end

  defp drop(socket) do
    Process.unlink(socket.channel_pid)
    ref = Process.monitor(socket.channel_pid)
    close(socket)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  defp send_event(socket, type, payload) do
    {:ok, event} = Event.new(type, payload)
    ref = push(socket, "event", Event.to_wire(event))
    assert_reply ref, :ok
  end

  defp inventory(env, state),
    do: %{environments: [%{env_id: env.id, slug: env.slug, state: state, containers: []}]}

  defp next_command do
    assert_push "command", %{"type" => type, "op_id" => op_id}
    {type, op_id}
  end

  describe "after a reboot" do
    test "an environment with a queued token refresh is still started", ctx do
      :ok = Environments.push_secrets(older_than: DateTime.utc_now())

      socket = join_box(ctx.box)
      {"env.secrets.write", write_id} = next_command()
      send_event(socket, "box.inventory", inventory(ctx.env, "stopped"))
      send_event(socket, "op.result", %{op_id: write_id, status: "ok"})

      {"env.start", _} = next_command()
    end

    test "an environment with some other operation in flight still gets its secrets and a start",
         ctx do
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
      {:ok, _} = Environments.logs(ctx.scope, ctx.env)
      assert_receive {:dispatch, %{type: "env.logs"}}
      Registry.unregister(Foreman.Registry, {:agent, ctx.box.id})

      socket = join_box(ctx.box)
      {"env.logs", logs_id} = next_command()
      send_event(socket, "box.inventory", inventory(ctx.env, "stopped"))
      assert Repo.reload!(ctx.env).observed_state == "stopped"
      send_event(socket, "op.result", %{op_id: logs_id, status: "error", error: "no container"})

      {"env.secrets.write", write_id} = next_command()
      send_event(socket, "op.result", %{op_id: write_id, status: "ok"})
      {"env.start", _} = next_command()
    end

    test "a start that was in flight gets its secrets rewritten before it's resent", ctx do
      {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
      env = Repo.update!(Ecto.Changeset.change(ctx.env, observed_state: "stopped"))

      {:ok, _} = Environments.start(ctx.scope, env)
      assert_receive {:dispatch, %{type: "env.secrets.write"} = write}
      {:ok, ev} = Event.new("op.result", %{op_id: write.op_id, status: "ok"})
      :ok = Agents.handle_event(ctx.box.id, ev)
      assert_receive {:dispatch, %{type: "env.start"} = start}
      Registry.unregister(Foreman.Registry, {:agent, ctx.box.id})

      _socket = join_box(ctx.box)
      {"env.secrets.write", _} = next_command()
      {"env.start", start_id} = next_command()
      assert start_id == start.op_id
    end
  end

  describe "box commands across a reconnect" do
    test "a result that arrives after the agent joins again isn't marked failed", ctx do
      admin = Scope.for_user(user_fixture(role: "admin"))
      socket = join_box(ctx.box)
      {:ok, gc} = Agents.run_box_command(admin, Boxes.get_box!(ctx.box.id), "box.gc")
      {"box.gc", _} = next_command()
      drop(socket)

      socket = join_box(ctx.box)
      send_event(socket, "op.result", %{op_id: gc.id, status: "ok", result: %{}})
      assert Operations.get!(gc.id).status == "succeeded"
    end

    defp sent_box_command(type, ago_seconds) do
      admin = Scope.for_user(user_fixture(role: "admin"))
      box = Boxes.get_box!(Repo.one!(from b in Foreman.Boxes.Box, limit: 1, select: b.id))
      {:ok, op} = Agents.run_box_command(admin, box, type)
      # Offline when sent, so it failed already; make one that was sent.
      Repo.update!(
        Ecto.Changeset.change(op,
          status: "dispatched",
          finished_at: nil,
          dispatched_at: DateTime.add(DateTime.utc_now(), -ago_seconds)
        )
      )
    end

    test "Housekeeping fails box commands that never come back" do
      inventory = sent_box_command("box.inventory", 15 * 60)

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      assert Operations.get!(inventory.id).status == "failed"
    end

    test "a gc gets longer than other box commands before it's given up on" do
      gc = sent_box_command("box.gc", 60 * 60)
      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      assert Operations.get!(gc.id).status == "dispatched"

      Repo.update!(
        Ecto.Changeset.change(gc, dispatched_at: DateTime.add(DateTime.utc_now(), -3 * 3600))
      )

      :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      assert Operations.get!(gc.id).status == "failed"
    end

    test "a result for an operation the control plane doesn't know is acknowledged", ctx do
      socket = join_box(ctx.box)
      send_event(socket, "op.result", %{op_id: Ecto.UUID.generate(), status: "ok"})
    end
  end

  describe "agent updates" do
    setup %{box: box} do
      # Short: the release's path is stored in a 255-character column.
      tmp = Path.join(System.tmp_dir!(), "fr-#{unique()}")
      File.mkdir_p!(tmp)
      {public, private} = Auth.generate_keypair()
      Application.put_env(:foreman, :agent_release_public_key, Base.encode64(public))
      Application.put_env(:foreman, :agent_release_dir, Path.join(tmp, "releases"))

      on_exit(fn ->
        Application.delete_env(:foreman, :agent_release_public_key)
        Application.delete_env(:foreman, :agent_release_dir)
        File.rm_rf!(tmp)
      end)

      tarball = Path.join(tmp, "agent.tar.gz")
      File.write!(tarball, "release bytes")
      sha = :crypto.hash(:sha256, "release bytes") |> Base.encode16(case: :lower)
      sig = Auth.sign_release("0.2.0", "linux-arm64", sha, private)
      {:ok, _} = Foreman.Agents.Releases.register("0.2.0", "linux-arm64", tarball, sig)

      Repo.update!(Ecto.Changeset.change(Repo.reload!(box), desired_agent_version: "0.2.0"))
      :ok
    end

    defp updates(box) do
      Repo.all(
        from o in Foreman.Operations.Operation,
          where: o.box_id == ^box.id and o.action == "agent.update",
          order_by: o.inserted_at
      )
    end

    test "checks that run at the same time start one update", ctx do
      box =
        Repo.update!(
          Ecto.Changeset.change(Repo.reload!(ctx.box),
            arch: "linux-arm64",
            agent_version: "0.1.0"
          )
        )

      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Foreman.Agents.Releases.maybe_update(box) end) end)
      |> Task.await_many()

      assert [_] = updates(box)
    end

    test "a blip during an update doesn't start a second one", ctx do
      socket = join_box(ctx.box)
      {"agent.update", _} = next_command()
      drop(socket)

      _socket = join_box(ctx.box)
      refute_push "command", %{"type" => "agent.update"}
      assert [%{status: "dispatched"}] = updates(ctx.box)
    end

    test "the update succeeds when the agent comes back on the new version", ctx do
      socket = join_box(ctx.box)
      {"agent.update", _} = next_command()
      drop(socket)

      _socket = join_box(ctx.box, %{"agent_version" => "0.2.0"})
      assert [%{status: "succeeded"}] = updates(ctx.box)
    end

    # What the agent reports once the new release is in place: it restarts
    # into it when it's idle.
    defp report_restart(socket, update_id) do
      send_event(socket, "op.result", %{
        op_id: update_id,
        status: "ok",
        result: %{"version" => "0.2.0", "restart" => true}
      })
    end

    # As if the update was sent, and reported, long enough ago that the
    # agent should have come back on the new version by now.
    defp age(update) do
      long_ago = DateTime.add(DateTime.utc_now(), -3 * 3600)

      args =
        if update.args["restart_reported_at"],
          do: %{"restart_reported_at" => DateTime.to_iso8601(long_ago)},
          else: %{}

      Repo.update!(
        Ecto.Changeset.change(update,
          dispatched_at: long_ago,
          args: Map.merge(update.args, args)
        )
      )
    end

    test "a reported restart isn't the end of the update", ctx do
      socket = join_box(ctx.box)
      {"agent.update", update_id} = next_command()
      report_restart(socket, update_id)
      assert [%{status: "running"}] = updates(ctx.box)
      drop(socket)

      # Back on the new version: done, nothing sent again.
      _socket = join_box(ctx.box, %{"agent_version" => "0.2.0"})
      refute_push "command", %{"type" => "agent.update"}
      assert [%{status: "succeeded"}] = updates(ctx.box)
    end

    test "the agent waiting to restart isn't taken for a failure", ctx do
      socket = join_box(ctx.box)
      {"agent.update", update_id} = next_command()
      report_restart(socket, update_id)
      drop(socket)

      # Still on the old version a few minutes on, after a blip: the agent
      # may be waiting for its operations to finish before it restarts.
      [update] = updates(ctx.box)

      Repo.update!(
        Ecto.Changeset.change(update, dispatched_at: DateTime.add(DateTime.utc_now(), -900))
      )

      _socket = join_box(ctx.box)
      refute_push "command", %{"type" => "agent.update"}
      assert [%{status: "running"}] = updates(ctx.box)
    end

    test "a version that didn't come up twice isn't sent again", ctx do
      # The agent reported the new release in place, but came back on the
      # old one: the new one crashed and systemd rolled it back.
      socket = join_box(ctx.box)
      {"agent.update", update_id} = next_command()
      report_restart(socket, update_id)
      drop(socket)
      [update] = updates(ctx.box)
      age(update)

      # Once could be bad luck (the network down at boot): it's tried again.
      socket = join_box(ctx.box)
      {"agent.update", update_id} = next_command()
      assert [%{status: "failed"}, %{status: "dispatched"}] = updates(ctx.box)
      assert Repo.reload!(ctx.box).failed_agent_version == nil
      report_restart(socket, update_id)
      drop(socket)
      age(List.last(updates(ctx.box)))

      # Twice isn't.
      socket = join_box(ctx.box)
      refute_push "command", %{"type" => "agent.update"}
      assert [%{status: "failed"}, %{status: "failed"}] = updates(ctx.box)
      assert Repo.reload!(ctx.box).failed_agent_version == "0.2.0"
      drop(socket)

      _socket = join_box(ctx.box)
      refute_push "command", %{"type" => "agent.update"}

      # Picking the version again tries again.
      admin = Scope.for_user(user_fixture(role: "admin"))
      box = Boxes.get_box!(ctx.box.id)
      {:ok, box} = Boxes.update_box(admin, box, %{"desired_agent_version" => "0.1.0"})
      {:ok, _} = Boxes.update_box(admin, box, %{"desired_agent_version" => "0.2.0"})
      {"agent.update", _} = next_command()
    end

    test "an update the agent couldn't install is tried again once", ctx do
      socket = join_box(ctx.box)
      {"agent.update", update_id} = next_command()

      send_event(socket, "op.result", %{
        op_id: update_id,
        status: "error",
        error: "download failed"
      })

      assert Repo.reload!(ctx.box).failed_agent_version == nil
      drop(socket)

      socket = join_box(ctx.box)
      {"agent.update", update_id} = next_command()

      send_event(socket, "op.result", %{
        op_id: update_id,
        status: "error",
        error: "download failed"
      })

      assert Repo.reload!(ctx.box).failed_agent_version == "0.2.0"
      drop(socket)

      _socket = join_box(ctx.box)
      refute_push "command", %{"type" => "agent.update"}
    end

    test "waits for the box's environments to finish what they're doing", ctx do
      {:ok, _} = Environments.stop(ctx.scope, ctx.env)
      socket = join_box(ctx.box)
      {"env.stop", stop_id} = next_command()
      refute_push "command", %{"type" => "agent.update"}

      send_event(socket, "op.result", %{op_id: stop_id, status: "ok"})
      :ok = Foreman.Jobs.Dispatch.perform(%Oban.Job{})
      {"agent.update", _} = next_command()
    end
  end
end
