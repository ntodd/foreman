defmodule Foreman.PortsTest do
  use Foreman.DataCase, async: false

  alias Foreman.{Environments, Ports}

  setup do
    box = box_fixture()
    env = environment_fixture(box: box)
    other = environment_fixture(box: box)
    %{box: box, env: env, other: other}
  end

  test "keeps each environment's latest ports", %{box: box, env: env, other: other} do
    # Not reported yet (an agent from before ports, say): unknown.
    assert Ports.for_environment(env.id) == nil

    :ok =
      Ports.record(box.id, %{
        env.id => [%{port: 4000, process: "beam.smp"}, %{port: 5173}],
        other.id => []
      })

    assert Ports.for_environment(env.id) == [%{port: 4000, process: "beam.smp"}, %{port: 5173}]
    assert Ports.for_environment(other.id) == []

    :ok = Ports.record(box.id, %{env.id => [%{port: 5173}], other.id => [%{port: 3000}]})
    assert Ports.for_environment(env.id) == [%{port: 5173}]
    assert Ports.for_environment(other.id) == [%{port: 3000}]
  end

  test "an environment left out of a report is unknown again: stopped, or unreadable",
       %{box: box, env: env, other: other} do
    :ok = Ports.record(box.id, %{env.id => [%{port: 4000}], other.id => [%{port: 3000}]})
    :ok = Ports.record(box.id, %{other.id => [%{port: 3000}]})

    assert Ports.for_environment(env.id) == nil
    assert Ports.for_environment(other.id) == [%{port: 3000}]
  end

  test "forgets an environment destroyed while it had ports", %{box: box, env: env} do
    :ok = Ports.record(box.id, %{env.id => [%{port: 4000}]})

    env
    |> Ecto.Changeset.change(destroyed_at: DateTime.utc_now())
    |> Foreman.Repo.update!()

    :ok = Ports.record(box.id, %{})
    assert Ports.for_environment(env.id) == nil
    assert :ets.match_object(Foreman.Ports, {env.id, :_, :_}) == []
  end

  test "ignores environments that aren't the box's", %{box: box, env: env} do
    elsewhere = environment_fixture(box: box_fixture())
    stranger = Ecto.UUID.generate()

    :ok = Ports.record(elsewhere.box_id, %{elsewhere.id => [%{port: 9000}]})

    :ok =
      Ports.record(box.id, %{
        env.id => [%{port: 4000}],
        elsewhere.id => [%{port: 6666}],
        stranger => [%{port: 7777}]
      })

    assert Ports.for_environment(elsewhere.id) == [%{port: 9000}]
    assert Ports.for_environment(stranger) == nil

    # And a report from one box doesn't clear another box's.
    :ok = Ports.record(box.id, %{})
    assert Ports.for_environment(elsewhere.id) == [%{port: 9000}]
  end

  test "ignores destroyed environments", %{box: box} do
    gone = environment_fixture(box: box, destroyed_at: DateTime.utc_now())
    :ok = Ports.record(box.id, %{gone.id => [%{port: 4000}]})
    assert Ports.for_environment(gone.id) == nil
  end

  test "tells the environment's page when its ports change, and only then",
       %{box: box, env: env, other: other} do
    Environments.subscribe(env.id)
    Environments.subscribe(other.id)

    :ok = Ports.record(box.id, %{env.id => [%{port: 4000}]})
    assert_receive {:ports, env_id, [%{port: 4000}]}
    assert env_id == env.id
    # `other` was unknown and still is.
    refute_receive {:ports, _, _}, 50

    :ok = Ports.record(box.id, %{env.id => [%{port: 4000}]})
    refute_receive {:ports, _, _}, 50

    other_id = other.id
    :ok = Ports.record(box.id, %{env.id => [], other.id => []})
    assert_receive {:ports, ^env_id, []}
    assert_receive {:ports, ^other_id, []}

    :ok = Ports.record(box.id, %{other.id => []})
    assert_receive {:ports, ^env_id, nil}
    refute_receive {:ports, _, _}, 50
  end

  test "caps what it keeps, whatever the agent sends", %{box: box, env: env} do
    ports = for p <- 1..500, do: %{port: p}
    :ok = Ports.record(box.id, %{env.id => ports})
    assert length(Ports.for_environment(env.id)) == 100
  end
end
