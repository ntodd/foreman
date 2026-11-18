defmodule Foreman.EnvironmentsRegistryAuthTest do
  @moduledoc """
  The repo owner's registry credentials go with every command that runs
  `devcontainer up`, so a private feature resolves on a start or restart
  as it did on the create. Agents on protocol 3 refuse the field on
  start and restart, so they get it on create and rebuild only.
  """
  use Foreman.DataCase

  alias Foreman.{Agents, Environments, Scope}
  alias ForemanProtocol.{Command, Event}

  setup do
    user = user_fixture()
    owner = owner_fixture()

    owner
    |> Ecto.Changeset.change(registry_token: "ghp_registry", registry_username: "machine")
    |> Repo.update!()

    repo = repo_fixture(owner: owner)
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, repo: repo, box: box, scope: Scope.for_user(user)}
  end

  defp on_protocol(box, version),
    do: box |> Ecto.Changeset.change(protocol_version: version) |> Repo.update!()

  defp stopped_env(ctx),
    do:
      environment_fixture(
        user: ctx.user,
        repo: ctx.repo,
        box: ctx.box,
        desired_state: "stopped",
        observed_state: "stopped"
      )

  # A start writes the secret files first and waits for the agent.
  defp started(ctx) do
    {:ok, _} = Environments.start(ctx.scope, stopped_env(ctx))
    assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
    {:ok, ev} = Event.new("op.result", %{op_id: write.op_id, status: "ok", result: %{}})
    :ok = Agents.handle_event(ctx.box.id, ev)
    dispatched("env.start")
  end

  defp dispatched(type) do
    assert_receive {:dispatch, %Command{type: ^type} = cmd}
    cmd.payload
  end

  describe "on protocol 4" do
    setup %{box: box}, do: %{box: on_protocol(box, 4)}

    test "a start carries them", ctx do
      assert [%{host: "ghcr.io", username: "machine", token: "ghp_registry"}] =
               started(ctx).registry_auth
    end

    test "a restart carries them", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)

      {:ok, _} = Environments.restart(ctx.scope, env, :all)
      assert [%{token: "ghp_registry"}] = dispatched("env.restart").registry_auth
    end
  end

  describe "on protocol 3" do
    setup %{box: box}, do: %{box: on_protocol(box, 3)}

    test "a start and a restart leave them out", ctx do
      refute Map.has_key?(started(ctx), :registry_auth)

      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, _} = Environments.restart(ctx.scope, env, :all)
      refute Map.has_key?(dispatched("env.restart"), :registry_auth)
    end

    test "a rebuild still carries them", ctx do
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      {:ok, _} = Environments.rebuild(ctx.scope, env)
      assert [%{token: "ghp_registry"}] = dispatched("env.rebuild").registry_auth
    end
  end
end
