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

    test "records the box firewall the agent reports", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      firewall = %{"firewall" => "missing", "firewall_default_bridge" => "reaches_tailnet"}

      assert {:ok, _, _} =
               subscribe_and_join(socket, "agent:#{box.id}", join_payload(firewall))

      box = Repo.reload!(box)
      assert box.firewall == "missing"
      assert box.firewall_default_bridge == "reaches_tailnet"
    end

    test "an agent that doesn't report the firewall leaves it unknown", %{box: box} do
      box |> Ecto.Changeset.change(firewall: "active") |> Repo.update!()
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))

      assert {:ok, _, _} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(%{"protocol_version" => 3})
               )

      assert Repo.reload!(box).firewall == nil
    end

    test "an agent that doesn't report a policy leaves it unknown", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      assert {:ok, _, _} = subscribe_and_join(socket, "agent:#{box.id}", join_payload())
      assert Repo.reload!(box).policy == nil
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

    test "a refused join doesn't mark the box offline", %{box: box} do
      {:ok, socket} = connect(AgentSocket, %{}, connect_info: signed_connect_info(box))
      Phoenix.PubSub.subscribe(Foreman.PubSub, "boxes")

      assert {:error, _} =
               subscribe_and_join(
                 socket,
                 "agent:#{box.id}",
                 join_payload(%{"protocol_version" => 99})
               )

      refute_receive {:box, :offline, _}
      assert Repo.reload!(box).last_seen_at == nil
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

    test "records the box firewall when it changes between joins", %{socket: socket, box: box} do
      {:ok, firewall} =
        Event.new("box.firewall", %{firewall: "missing", firewall_default_bridge: "filtered"})

      ref = push(socket, "event", Event.to_wire(firewall))
      assert_reply ref, :ok
      box = Repo.reload!(box)
      assert box.firewall == "missing"
      assert box.firewall_default_bridge == "filtered"
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

    test "records the box's environments' listening ports", %{socket: socket, box: box} do
      env = environment_fixture(box: box)
      Foreman.Environments.subscribe(env.id)

      {:ok, ports} =
        Event.new("box.ports", %{environments: %{env.id => [%{port: 4000, process: "beam.smp"}]}})

      ref = push(socket, "event", Event.to_wire(ports))
      assert_reply ref, :ok
      assert_receive {:ports, _, [%{port: 4000, process: "beam.smp"}]}
      assert Foreman.Ports.for_environment(env.id) == [%{port: 4000, process: "beam.smp"}]
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
