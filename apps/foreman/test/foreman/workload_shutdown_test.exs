defmodule Foreman.WorkloadShutdownTest do
  use ForemanWeb.ConnCase
  import Mox
  import Foreman.PublicAPIMutationFixtures

  alias Foreman.{Agents, Environments, OAuth, Operations, Repo, Repos, Scope}
  alias Foreman.Environments.Server
  alias Foreman.GitHub.ClientMock
  alias Foreman.Jobs.EnvironmentExpiry
  alias Foreman.PublicAPI.Mutations

  setup do
    old = Application.fetch_env(:foreman, :github_app)

    Application.put_env(:foreman, :github_app, %{
      client_id: "test",
      client_secret: "test",
      private_key: "test"
    })

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:foreman, :github_app, value)
        :error -> Application.delete_env(:foreman, :github_app)
      end
    end)

    admin = Scope.for_user(user_fixture(role: "admin"))
    user = user_fixture()
    owner = owner_fixture()
    name = "#{owner.login}/workload"
    id = unique()
    verify_repo = fn _, ^name -> {:ok, %{"full_name" => name, "id" => id}} end
    stub(ClientMock, :get_repo, verify_repo)
    {:ok, repo} = Repos.add_repo(admin, name)
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo, box: box)
    {actor, _} = principal(user)
    {_, reader} = principal(user, ["operations:read"])
    token = OAuth.issue(reader, reader.scopes, :user).access_token
    %{env: env, admin: admin, box: box, actor: actor, token: token, verify_repo: verify_repo}
  end

  defp read(token, id) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/api/v1/operations/#{id}")
    |> json_response(200)
  end

  defp event(box, type, id, attrs) do
    {:ok, event} = ForemanProtocol.Event.new(type, Map.put(attrs, :op_id, id))
    :ok = Agents.handle_event(box.id, event)
  end

  for action <- [:stop, :destroy] do
    @action action

    test "an administrator's #{@action} supersedes a queued matching API shutdown during an outage",
         ctx do
      action = Atom.to_string(@action)
      type = "env." <> action
      {:ok, _, first} = Mutations.operate(ctx.actor, ctx.env.id, "first", %{"action" => action})
      assert Operations.get!(first).status == "queued"
      stub(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
      :ok = Agents.register(ctx.box.id)
      :ok = Agents.agent_connected(ctx.box)
      refute Operations.in_flight(ctx.env.id)
      {:ok, admin} = apply(Environments, @action, [ctx.admin, Repo.reload!(ctx.env)])
      assert_receive {:dispatch, %{type: ^type, op_id: id}}
      assert id == admin.id
      event(ctx.box, "op.result", id, %{status: "ok"})
      refute_received {:dispatch, _}
      stub(ClientMock, :get_repo, ctx.verify_repo)
      assert %{"status" => "cancelled"} = read(ctx.token, first)
      assert %{"status" => "succeeded"} = read(ctx.token, id)
    end

    test "an administrator's #{@action} waits for the agent's matching running operation", ctx do
      action = Atom.to_string(@action)
      type = "env." <> action
      :ok = Agents.register(ctx.box.id)
      {:ok, _, first} = Mutations.operate(ctx.actor, ctx.env.id, "first", %{"action" => action})
      Server.kick(ctx.env.id)
      assert_receive {:dispatch, %{type: ^type, op_id: ^first}}
      event(ctx.box, "op.accepted", first, %{})
      stub(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
      {:ok, admin} = apply(Environments, @action, [ctx.admin, Repo.reload!(ctx.env)])
      :ok = Agents.restart_clocks(ctx.box.id, [first])
      :ok = Agents.agent_connected(ctx.box)
      assert Operations.get!(first).status == "running"
      assert Repo.reload!(admin).status == "queued"
      refute_received {:dispatch, _}
      event(ctx.box, "op.result", first, %{status: "error", error: "fixture shutdown failed"})
      assert_receive {:dispatch, %{type: ^type, op_id: next}}
      assert next == admin.id
      event(ctx.box, "op.result", next, %{status: "ok"})
      stub(ClientMock, :get_repo, ctx.verify_repo)

      assert %{"status" => "failed", "error" => %{"code" => "operation_failed"}} =
               read(ctx.token, first)

      assert %{"status" => "succeeded"} = read(ctx.token, next)
    end

    test "a running #{@action} expiry retry keeps its physical outcome after its sibling fulfills the policy",
         ctx do
      action = Atom.to_string(@action)
      type = "env." <> action

      Repo.update!(
        Ecto.Changeset.change(ctx.env, expiry_at: DateTime.utc_now(), expiry_action: action)
      )

      :ok = Agents.register(ctx.box.id)
      job = %{args: %{"environment_id" => ctx.env.id}}
      :ok = EnvironmentExpiry.perform(job)
      assert_receive {:dispatch, %{type: ^type, op_id: first}}

      {:ok, _, _} =
        Operations.timed_out(
          Operations.get!(first),
          "original timeout",
          &Environments.record_result/1
        )

      :ok = EnvironmentExpiry.perform(job)
      assert_receive {:dispatch, %{type: ^type, op_id: retry}}
      event(ctx.box, "op.accepted", retry, %{})
      event(ctx.box, "op.result", first, %{status: "ok"})
      assert Repo.reload!(ctx.env).expiry_consumed_at
      :ok = Agents.restart_clocks(ctx.box.id, [retry])
      :ok = Agents.agent_connected(ctx.box)
      refute_received {:dispatch, %{type: ^type}}
      assert %{"status" => "running"} = read(ctx.token, retry)
      event(ctx.box, "op.result", retry, %{status: "ok"})
      assert %{"status" => "succeeded"} = read(ctx.token, retry)
      assert %{"error" => %{"code" => "operation_timeout"}} = read(ctx.token, first)
    end
  end
end
