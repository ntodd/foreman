defmodule ForemanWeb.AgentChannelTest do
  use ForemanWeb.ChannelCase

  alias Foreman.{Environments, Repo, Scope}
  alias ForemanProtocol.{Auth, Event}
  alias ForemanWeb.AgentSocket

  setup do
    user = user_fixture()
    box = box_fixture(owner_user_id: user.id)
    %{user: user, box: box}
  end

  describe "connect" do
    test "accepts a correctly signed connect", %{box: box} do
      assert {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      assert socket.assigns.box_id == box.id
      assert AgentSocket.id(socket) == "agent_socket:#{box.id}"
    end

    test "refuses a replayed connect", %{box: box} do
      info = signed_connect_info(box)
      assert {:ok, _} = connect(AgentSocket, %{}, connect_info: info)
      assert :error = connect(AgentSocket, %{}, connect_info: info)
    end

    test "refuses stale clocks, other keys, unknown and revoked agents", %{box: box} do
      assert :error =
               connect(AgentSocket, %{},
                 connect_info: signed_connect_info(box, now: System.os_time(:second) - 120)
               )

      impostor = %{box | __private_key__: elem(Auth.generate_keypair(), 1)}
      assert :error = connect(AgentSocket, %{}, connect_info: signed_connect_info(impostor))

      stranger = %{box | id: Ecto.UUID.generate()}
      assert :error = connect(AgentSocket, %{}, connect_info: signed_connect_info(stranger))

      {:ok, _} =
        Foreman.Boxes.revoke(Scope.for_user(user_fixture(role: "admin")), Repo.reload!(box))

      assert :error = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
    end

    test "refuses a connect with no headers" do
      assert :error =
               connect(AgentSocket, %{},
                 connect_info: %{x_headers: [], peer_data: %{address: {127, 0, 0, 1}}}
               )
    end
  end

  describe "join" do
    test "only the agent's own topic", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      other = box_fixture()

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "agent:#{other.id}", join_payload())

      assert {:ok, _, _socket} = subscribe_and_join(socket, "agent:#{box.id}", join_payload())
      assert Foreman.Boxes.online?(box.id)
      assert Repo.reload!(box).hostname == "desktop"
    end

    test "records the policy the agent reports", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      policy = Map.put(ForemanProtocol.Policy.defaults(), "privileged", "allow")

      assert {:ok, _, _} =
               subscribe_and_join(socket, "agent:#{box.id}", join_payload(%{"policy" => policy}))

      assert Repo.reload!(box).policy == policy
    end

    test "an agent that doesn't report a policy leaves it unknown", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      assert {:ok, _, _} = subscribe_and_join(socket, "agent:#{box.id}", join_payload())
      assert Repo.reload!(box).policy == nil
    end

    test "records how the box isolates environments", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))

      assert {:ok, _, _} =
               subscribe_and_join(socket, "agent:#{box.id}", join_payload(%{"isolation" => "vm"}))

      assert Repo.reload!(box).isolation == "vm"
    end

    # An agent rolled back to a release before protocol 3 can only run containers.
    test "an agent on protocol 2 runs containers, whatever the box said before", %{box: box} do
      box |> Ecto.Changeset.change(isolation: "vm") |> Repo.update!()
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))

      assert {:ok, _, _} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(%{"protocol_version" => 2})
               )

      assert Repo.reload!(box).isolation == "container"
    end

    # v0.2.0 speaks protocol 1, and joining is the only way it's sent an update.
    test "an agent on protocol 1 still joins, so it can be updated", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))

      assert {:ok, _, _} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(%{"protocol_version" => 1})
               )

      assert %{protocol_version: 1, isolation: "container"} = Repo.reload!(box)
    end

    test "refuses protocol versions it doesn't speak", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))

      assert {:error, %{reason: "unsupported protocol version"}} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(%{"protocol_version" => 99})
               )
    end
  end

  describe "commands and events" do
    setup %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      {:ok, _, socket} = subscribe_and_join(socket, "agent:#{box.id}", join_payload())
      %{socket: socket}
    end

    test "pushes queued work on join, and applies results sent back", %{
      socket: socket,
      box: box,
      user: user
    } do
      repo = repo_fixture()

      {:ok, env} =
        Environments.create_environment(Scope.for_user(user), %{
          "repo_id" => repo.id,
          "box_id" => box.id
        })

      assert_push "command", %{"type" => "env.create", "op_id" => op_id, "payload" => payload}
      assert payload["env_id"] == env.id

      {:ok, accepted} = Event.new("op.accepted", %{op_id: op_id})
      ref = push(socket, "event", Event.to_wire(accepted))
      assert_reply ref, :ok

      {:ok, log} = Event.new("op.log", %{op_id: op_id, stream: "info", data: "Building image\n"})
      ref = push(socket, "event", Event.to_wire(log))
      assert_reply ref, :ok

      {:ok, result} =
        Event.new("op.result", %{op_id: op_id, status: "ok", result: %{"remote_user" => "vscode"}})

      ref = push(socket, "event", Event.to_wire(result))
      assert_reply ref, :ok

      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.remote_user == "vscode"
      assert Foreman.Operations.log(Foreman.Operations.get!(op_id)) =~ "Building image"
    end

    test "rejects malformed events", %{socket: socket} do
      ref = push(socket, "event", %{"type" => "op.result", "payload" => %{"op_id" => "nope"}})
      assert_reply ref, :error, %{reason: "invalid event"}

      ref = push(socket, "exec", %{"cmd" => "id"})
      assert_reply ref, :error
    end

    test "records stats and inventory", %{socket: socket, box: box} do
      {:ok, stats} =
        Event.new("box.stats", %{
          capacity: %{cpus: 8, memory_mb: 32_768, disk_mb: 100, disk_free_mb: 50},
          environments: %{}
        })

      ref = push(socket, "event", Event.to_wire(stats))
      assert_reply ref, :ok
      assert Repo.reload!(box).capacity["cpus"] == 8
    end

    test "records host metrics", %{socket: socket, box: box} do
      Foreman.Metrics.subscribe(box.id)

      {:ok, metrics} =
        Event.new("box.metrics", %{
          at: System.system_time(:second),
          cpu_percent: 42.0,
          memory_total_mb: 8_000,
          memory_used_mb: 2_000,
          disk_total_mb: 100,
          disk_used_mb: 60
        })

      ref = push(socket, "event", Event.to_wire(metrics))
      assert_reply ref, :ok
      assert_receive {:box_metrics, _, %{cpu: 42.0, memory_used: 2_000}}
    end

    test "records per-environment usage for the box's own environments", %{
      socket: socket,
      box: box
    } do
      env = environment_fixture(box: box)
      stranger = Ecto.UUID.generate()

      {:ok, stats} =
        Event.new("box.stats", %{
          capacity: %{cpus: 8, memory_mb: 32_768},
          environments: %{
            env.id => %{cpu_percent: 25.0, memory_mb: 512},
            stranger => %{cpu_percent: 99.0, memory_mb: 9_999}
          }
        })

      ref = push(socket, "event", Event.to_wire(stats))
      assert_reply ref, :ok

      assert %{series: [%{slug: slug, cpu: [{_, 25.0}]}]} =
               Foreman.Metrics.env_series(box.id, "15m")

      assert slug == env.slug
    end
  end
end
