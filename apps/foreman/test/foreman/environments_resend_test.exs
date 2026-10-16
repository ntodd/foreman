defmodule Foreman.EnvironmentsResendTest do
  @moduledoc """
  Operations in flight when an agent reconnects are rebuilt and sent
  again. When the rebuild fails, the operation mustn't sit there as if it
  were on the box, holding up everything queued behind it.
  """
  use Foreman.DataCase

  import Mox

  alias Foreman.{Agents, Environments, Operations, Scope}
  alias Foreman.Environments.Server
  alias ForemanProtocol.{Command, Event}

  setup :verify_on_exit!

  setup do
    Application.put_env(:foreman, :tailscale, %{
      client_id: "c",
      client_secret: "s",
      tailnet: "-",
      tags: []
    })

    on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)

    user = user_fixture()
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, repo: repo, box: box, scope: Scope.for_user(user)}
  end

  test "an operation that can't be rebuilt for a resend fails, and the queue moves on", ctx do
    expect(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ ->
      {:ok, %{key: "tskey-auth-1", id: "k1"}}
    end)

    {:ok, env} =
      Environments.create_environment(ctx.scope, %{
        "repo_id" => ctx.repo.id,
        "box_id" => ctx.box.id
      })

    assert_receive {:dispatch, %Command{type: "env.create"} = create}
    {:ok, _} = Environments.stop(ctx.scope, Repo.reload!(env))
    refute_receive {:dispatch, _}

    # The agent reconnects with the create in flight, and this time the
    # command can't be built.
    Repo.update!(Ecto.Changeset.change(Repo.reload!(env), ts_authkey: nil))
    expect(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ -> {:error, :boom} end)
    Server.resend(env.id, create.op_id)

    failed = Operations.get!(create.op_id)
    assert failed.status == "failed"
    assert failed.error =~ "Tailscale auth key"
    assert_receive {:dispatch, %Command{type: "env.stop"}}

    # If the box was running it after all, its result still counts.
    {:ok, ev} =
      Event.new("op.result", %{
        op_id: create.op_id,
        status: "ok",
        result: %{"remote_user" => "vscode"}
      })

    :ok = Agents.handle_event(ctx.box.id, ev)
    assert Operations.get!(create.op_id).status == "succeeded"
  end
end
