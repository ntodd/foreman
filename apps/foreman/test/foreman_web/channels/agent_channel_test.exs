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
  end
end
