defmodule Foreman.EnvironmentsCommandsTest do
  @moduledoc "What goes into an environment's commands when GitHub misbehaves."
  use Foreman.DataCase

  import Mox

  alias Foreman.{Accounts, Agents, Environments, Scope}
  alias Foreman.GitHub.ClientMock
  alias ForemanProtocol.{Command, Event}

  setup :verify_on_exit!

  setup do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:foreman, :github_app) end)

    user = user_fixture(access_token: "ghu_ok")
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo_fixture(), box: box)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    %{user: user, box: box, env: env, scope: Scope.for_user(user)}
  end

  defp report(box, cmd, payload) do
    {:ok, ev} = Event.new("op.result", Map.put(payload, :op_id, cmd.op_id))
    :ok = Agents.handle_event(box.id, ev)
  end

  defp on_protocol(box, version),
    do: box |> Ecto.Changeset.change(protocol_version: version) |> Repo.update!()

  describe "a GitHub error while writing secrets" do
    setup ctx do
      ctx.env
      |> Ecto.Changeset.change(token_pushed_at: DateTime.utc_now())
      |> Repo.update!()

      :ok
    end

    test "still sends the files, and tells a protocol 2 agent to keep its token", ctx do
      on_protocol(ctx.box, 2)

      expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
        {:error, {:http, 502, "Bad Gateway"}}
      end)

      :ok = Environments.push_secrets()
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = cmd}
      refute Map.has_key?(cmd.payload.files, "github-token")
      assert cmd.payload.keep == ["github-token"]
      assert cmd.payload.files["notices"] =~ "Foreman will try again"
      assert Map.has_key?(cmd.payload.files, "secrets.env")

      report(ctx.box, cmd, %{status: "ok", result: %{"files" => [], "kept" => ["github-token"]}})
      # The token wasn't renewed, so it's first in line for the next refresh.
      assert is_nil(Repo.reload!(ctx.env).token_pushed_at)
    end

    test "never sends keep to a protocol 1 agent, which would refuse it", ctx do
      on_protocol(ctx.box, 1)

      expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
        {:error, {:http, 502, "Bad Gateway"}}
      end)

      :ok = Environments.push_secrets()
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = cmd}
      refute Map.has_key?(cmd.payload, :keep)
      refute "keep" in Map.keys(Command.to_wire(cmd)["payload"])
      refute Map.has_key?(cmd.payload.files, "github-token")
      assert cmd.payload.files["notices"] =~ "Foreman will try again"
    end

    test "a permanent error (a repo the app can't see) still sends the files", ctx do
      on_protocol(ctx.box, 2)

      expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
        {:error, {:http, 422, "not accessible to the parent installation"}}
      end)

      :ok = Environments.push_secrets()
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = cmd}
      assert cmd.payload.keep == ["github-token"]
    end
  end

  test "an expired login still clears the token and says so", ctx do
    ctx.user
    |> Ecto.Changeset.change(refresh_token: nil, access_token_expires_at: DateTime.utc_now())
    |> Repo.update!()

    on_protocol(ctx.box, 2)
    :ok = Environments.push_secrets()
    assert_receive {:dispatch, %Command{type: "env.secrets.write"} = cmd}
    refute Map.has_key?(cmd.payload.files, "github-token")
    # The token is dead; there's nothing worth keeping.
    refute Map.has_key?(cmd.payload, :keep)
    assert cmd.payload.files["notices"] =~ "GitHub login expired"
  end

  test "a GitHub error during a rebuild goes ahead without a token and retries it soon", ctx do
    expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
      {:error, {:http, 502, "Bad Gateway"}}
    end)

    ctx.env
    |> Ecto.Changeset.change(token_pushed_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, _} = Environments.rebuild(ctx.scope, Repo.reload!(ctx.env))
    assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}
    assert cmd.payload.files["notices"] =~ "Foreman will try again"
    report(ctx.box, cmd, %{status: "ok", result: %{"remote_user" => "vscode"}})

    # The env holds no token now, so it's first in line for the next refresh.
    assert is_nil(Repo.reload!(ctx.env).token_pushed_at)
  end

  describe "the user's own devcontainer features" do
    @orca "ghcr.io/ntodd/devcontainer-features/orca:1"
    @node "ghcr.io/devcontainers/features/node:1"

    setup ctx do
      stub(ClientMock, :scope_user_token, fn _, _, _, _, _ -> {:error, {:http, 502, "x"}} end)
      on_protocol(ctx.box, 3)

      {:ok, _} =
        Accounts.update_features(ctx.scope, %{@orca => %{"server" => true}, @node => %{}})

      :ok
    end

    defp rebuild(ctx) do
      {:ok, _} =
        Environments.rebuild(Scope.for_user(Repo.reload!(ctx.user)), Repo.reload!(ctx.env))

      assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}
      report(ctx.box, cmd, %{status: "ok", result: %{"remote_user" => "vscode"}})
      cmd
    end

    test "go on a rebuild, less the ones turned off for the repo", ctx do
      assert rebuild(ctx).payload.features == %{@orca => %{"server" => true}, @node => %{}}

      repo = Repo.preload(ctx.env, :repo).repo

      {:ok, _} =
        Accounts.put_repo_setting(ctx.scope, repo, %{
          "disabled_features" => ["ghcr.io/devcontainers/features/node"]
        })

      assert rebuild(ctx).payload.features == %{@orca => %{"server" => true}}
    end

    test "are left out for an agent older than protocol 3, which would refuse them", ctx do
      on_protocol(ctx.box, 2)
      cmd = rebuild(ctx)
      refute Map.has_key?(cmd.payload, :features)
    end

    test "are left out of the command when there are none", ctx do
      {:ok, _} = Accounts.update_features(Scope.for_user(Repo.reload!(ctx.user)), %{})
      cmd = rebuild(ctx)
      refute Map.has_key?(cmd.payload, :features)
      refute "features" in Map.keys(Command.to_wire(cmd)["payload"])
    end
  end
end
