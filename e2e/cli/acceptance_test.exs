Code.require_file("support.exs", __DIR__)

defmodule Foreman.CLIAcceptanceTest do
  use Foreman.DataCase

  import Foreman.CLITestSupport
  import Foreman.PublicAPIMutationFixtures, only: [local_git: 1]

  alias Foreman.Agents
  alias Foreman.Environments.Environment
  alias Foreman.Operations.{LogStore, Operation}
  alias ForemanProtocol.Event

  @moduletag :tmp_dir
  setup :local_git
  setup :listener

  setup do
    user = user_fixture(role: "member")
    repo = repo_fixture() |> change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    :ok = Agents.register(box.id)
    %{user: user, repo: repo, box: box}
  end

  @tag :legacy_upgrade
  test "upgrade rotates a Python checkout connection across concurrent processes, then revokes it",
       ctx do
    checkout = Path.expand("../../bin/foreman", __DIR__)
    login(%{ctx | cli: checkout}, ctx.user, "repos:list")

    # Only the local refresh deadline moves. The issued credentials stay real.
    hash = fn value -> :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) end
    account = ctx.user.id

    path =
      Path.join([ctx.tmp_dir, "state", "foreman", hash.(ctx.origin), hash.(account) <> ".json"])

    old = path |> File.read!() |> Jason.decode!()
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    File.write!(path, Jason.encode!(%{old | "expires" => 0}))

    args = ["--instance", ctx.origin, "--account", account]
    clients = for _ <- 1..4, do: launch(ctx, args ++ ["me"])

    for client <- clients do
      me = client |> finish() |> success() |> Jason.decode!()
      assert %{"id" => ^account, "kind" => "user", "client_id" => "foreman-cli"} = me
    end

    next = path |> File.read!() |> Jason.decode!()
    assert next["refresh_token"] != old["refresh_token"], "No refresh occurred"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    ctx |> launch(args ++ ["logout"]) |> finish() |> success()
    refute File.exists?(path)
    response = Req.get!(ctx.origin <> "/api/v1/me", auth: {:bearer, next["access_token"]})
    assert response.status == 401
  end

  test "default personal login restores the account, follows discovery pages and respects ownership",
       ctx do
    foreign = environment_fixture(repo: ctx.repo)
    owner = owner_fixture(login: "000-first")

    for n <- 1..50,
        do:
          repo_fixture(owner: owner, name: "page-#{n}")
          |> change(private: false)
          |> Repo.update!()

    login(ctx, ctx.user)
    assert json(ctx, ["me"])["id"] == ctx.user.id
    repos = json(ctx, ["repo", "list"]) |> items()
    assert length(repos) == 51
    assert List.last(repos)["id"] == ctx.repo.id
    assert [%{"id" => box_id}] = json(ctx, ["box", "list"]) |> items()
    assert box_id == ctx.box.id
    assert [] == json(ctx, ["env", "list"]) |> items()

    assert {%{"code" => "resource_not_found"}, "", _} = failure(ctx, ["env", "show", foreign.id])
    key = Ecto.UUID.generate()
    created = json(ctx, ["env", "create", ctx.repo.full_name, "--request-key", key, "--no-wait"])
    id = created["environment_id"]
    op = created["operation_id"]
    assert [%{"id" => ^id}] = json(ctx, ["env", "list"]) |> items()
    assert %{"id" => ^op, "action" => "create"} = json(ctx, ["op", "show", op])
    shown = json(ctx, ["env", "show", id])
    assert {shown["branch"], shown["box_id"]} == {ctx.repo.default_branch, ctx.box.id}

    assert {%{"code" => "insufficient_scope"}, "", _} =
             failure(ctx, ["env", "destroy", id, "--yes"])

    complete(ctx.box, op)

    Repo.get!(Operation, op)
    |> change(finished_at: DateTime.add(DateTime.utc_now(), -91, :day))
    |> Repo.update!()

    assert %{
             "operation_history_expired" => true,
             "environment_id" => ^id,
             "operation_id" => ^op,
             "environment" => %{"id" => ^id}
           } = json(ctx, ["env", "create", "--resume", key])

    other = user_fixture()
    device_login(ctx, other, ["--instance", ctx.origin, "--account", other.id, "login"])
    assert json(ctx, ["me"])["id"] == other.id
    assert json(ctx, ["--account", ctx.user.id, "me"])["id"] == ctx.user.id
    assert [] == json(ctx, ["env", "list"]) |> items()
    {error, "", _} = failure(ctx, ["env", "create", "--resume", key, "--no-wait"])
    assert error["code"] in ["request_identity_mismatch", "request_not_found"]
    ctx |> launch(["--account", other.id, "logout"]) |> finish() |> success()

    assert json(ctx, ["--instance", ctx.origin, "--account", ctx.user.id, "me"])["id"] ==
             ctx.user.id

    assert Repo.aggregate(Environment, :count) == 2
  end

  test "create-only authorization submits by UUID and preserves accepted IDs on a wait error",
       ctx do
    login(ctx, ctx.user, "environments:create")
    assert {%{"code" => "insufficient_scope"}, "", _} = failure(ctx, ["repo", "list"])
    receipt = json(ctx, ["env", "create", ctx.repo.id, "--box", ctx.box.id, "--no-wait"])
    assert {:ok, id} = Ecto.UUID.cast(receipt["environment_id"])
    assert {:ok, _} = Ecto.UUID.cast(receipt["operation_id"])
    assert {%{"code" => "insufficient_scope"}, "", _} = failure(ctx, ["env", "show", id])
    {error, _, _} = failure(ctx, ["env", "create", ctx.repo.id])

    assert %{"code" => "insufficient_scope", "environment_id" => env, "operation_id" => op} =
             error

    assert env != id and Repo.get!(Operation, op).environment_id == env
    assert Repo.aggregate(Environment, :count) == 2
  end

  @tag :hold_create
  test "a killed create resumes its saved request, and a stopped wait leaves accepted work running",
       ctx do
    login(ctx, ctx.user)

    child =
      launch(ctx, [
        "--json",
        "env",
        "create",
        ctx.repo.full_name,
        "--branch",
        "topic",
        "--no-wait"
      ])

    assert_receive {:accepted, handler, key, %{"environment_id" => id, "operation_id" => op}},
                   5_000

    try do
      interrupt(child, "KILL")
      assert {status, "", diagnostic} = finish(child)
      assert status != 0 and diagnostic =~ key
    after
      send(handler, :release_response)
    end

    assert %{"environment_id" => ^id, "operation_id" => ^op} =
             json(ctx, ["env", "create", "--resume", key, "--no-wait"])

    assert [%{id: ^id, branch: "topic"}] = Repo.all(Environment)
    assert [%{id: ^op}] = Repo.all(from o in Operation, where: o.environment_id == ^id)
    waiter = launch(ctx, ["--json", "op", "wait", op])
    assert_receive {:read_operation, ^op}, 5_000
    interrupt(waiter, "INT")
    {status, _, _} = finish(waiter)
    assert status != 0

    assert {%{"code" => "wait_timeout"}, "", _} =
             failure(ctx, ["op", "wait", op, "--timeout", "200ms"])

    assert {%{"code" => "lifecycle_conflict"}, "", _} =
             failure(ctx, ["env", "stop", id, "--no-wait"])

    event(ctx.box, "op.result", %{
      op_id: op,
      status: "error",
      error: "fixture provisioning failed"
    })

    assert {%{"code" => "operation_failed", "message" => message}, "", _} =
             failure(ctx, ["op", "wait", op])

    assert message =~ "fixture provisioning failed"
  end

  test "state, readiness, terminal log pages and operation history survive CLI restarts", ctx do
    login(ctx, ctx.user, Enum.join(Foreman.OAuth.Scopes.all(), " "))
    key = Ecto.UUID.generate()

    args = [
      "env",
      "create",
      ctx.repo.id,
      "--request-key",
      key,
      "--box",
      ctx.box.name,
      "--no-wait"
    ]

    %{"environment_id" => id, "operation_id" => create} = json(ctx, args)

    assert %{"environment_id" => ^id, "operation_id" => ^create} = json(ctx, args)

    assert {%{"code" => "idempotency_conflict"}, "", _} =
             failure(ctx, args ++ ["--branch", "other"])

    complete(ctx.box, create)
    sample(ctx.box, id, ["workspace"])

    assert %{"readiness" => "ready", "observed_state" => "running", "desired_state" => "running"} =
             json(ctx, ["env", "show", id])

    Registry.unregister(Foreman.Registry, {:agent, ctx.box.id})
    assert json(ctx, ["env", "show", id])["readiness"] == "unknown"
    assert json(ctx, ["op", "show", create])["status"] == "succeeded"
    :ok = Agents.register(ctx.box.id)

    %{"operation_id" => stop} = json(ctx, ["env", "stop", id, "--no-wait"])
    complete(ctx.box, stop)
    sample(ctx.box, id, [])

    assert %{"readiness" => "not_ready", "observed_state" => "stopped"} =
             json(ctx, ["env", "show", id])

    assert %{"environment_id" => ^id} = json(ctx, ["env", "stop", id])

    starter = launch(ctx, ["--json", "env", "start", id])
    assert_receive {:read_operation, start} when start != create and start != stop, 5_000
    sample(ctx.box, id, ["workspace"])
    complete(ctx.box, start)

    assert %{
             "operation" => %{"id" => ^start, "status" => "succeeded"},
             "environment" => %{"readiness" => "ready"}
           } =
             starter |> finish() |> success() |> Jason.decode!()

    {status, _, _} = ctx |> launch(["env", "destroy", id]) |> finish()
    assert status != 0
    refute Repo.exists?(from o in Operation, where: o.action == "destroy")
    %{"operation_id" => destroy} = json(ctx, ["env", "destroy", id, "--yes", "--no-wait"])
    complete(ctx.box, destroy)

    assert {%{"code" => "original_environment_gone"}, "", _} = failure(ctx, args)
    assert [] == json(ctx, ["env", "list"]) |> items()
    history = json(ctx, ["op", "list", id]) |> items()

    assert MapSet.new(history, &{&1["id"], &1["status"]}) ==
             MapSet.new([create, stop, start, destroy], &{&1, "succeeded"})

    # Read a bounded rolling log across several API pages after the env is gone.
    # Resume from the first returned cursor; all later bytes must match exactly.
    tail = String.duplicate("x", 1_048_576 - 4) <> "END\n"
    {:ok, :ok} = LogStore.append(create, "DISCARDED\n" <> tail)
    pages = log_pages(ctx, create, [])
    [first | rest] = Enum.reject(pages, &(&1["text"] == ""))
    assert first["truncated"] and is_binary(first["next_cursor"])
    assert rest != []
    assert Enum.map_join(pages, & &1["text"]) == tail
    assert %{"text" => ^tail, "truncated" => true} = json(ctx, ["op", "logs", create])
    resumed = log_pages(ctx, create, ["--cursor", first["next_cursor"]])
    assert Enum.map_join(resumed, & &1["text"]) == Enum.map_join(rest, & &1["text"])
  end

  test "log follow stays attached across empty pages until the final output is drained", ctx do
    login(ctx, ctx.user)
    %{"operation_id" => op} = json(ctx, ["env", "create", ctx.repo.id, "--no-wait"])
    follower = launch(ctx, ["--json", "op", "logs", op, "--follow"])
    assert_receive {:read_log, ^op, true, _}, 5_000
    {:ok, :ok} = LogStore.append(op, "before\n")
    assert_receive {:read_log, ^op, false, cursor}, 5_000
    assert_receive {:read_log, ^op, true, ^cursor}, 5_000
    {:ok, :ok} = LogStore.append(op, "after\n")
    complete(ctx.box, op)
    pages = follower |> finish() |> success() |> decode_pages()
    assert Enum.map_join(pages, & &1["text"]) == "before\nafter\n"
  end

  test "pinned placement requires warning acknowledgement and enforces hard capacity", ctx do
    login(ctx, ctx.user)
    ctx.repo |> change(cpu_limit: 30.0) |> Repo.update!()
    box = ctx.box |> change(capacity_policy: "warn") |> Repo.update!()
    args = ["env", "create", ctx.repo.id, "--box", box.name, "--no-wait"]
    assert {%{"code" => "capacity_confirmation_required"}, "", _} = failure(ctx, args)
    assert Repo.aggregate(Environment, :count) == 0
    assert %{"operation_id" => op} = json(ctx, args ++ ["--confirm-capacity-warning"])
    assert Repo.get!(Operation, op).box_id == box.id
    box |> change(capacity_policy: "refuse") |> Repo.update!()

    assert {%{"code" => "capacity_exceeded"}, "", _} =
             failure(ctx, args ++ ["--confirm-capacity-warning"])

    assert Repo.aggregate(Environment, :count) == 1
  end

  for policy <- ~w(stop destroy) do
    @policy policy
    test "a CLI-created workspace runs its #{@policy} expiry policy", ctx do
      login(ctx, ctx.user, Enum.join(Foreman.OAuth.Scopes.all(), " "))

      deadline = DateTime.add(DateTime.utc_now(), 120) |> DateTime.truncate(:second)
      at = DateTime.to_iso8601(deadline)

      %{"environment_id" => id, "operation_id" => create} =
        json(ctx, [
          "env",
          "create",
          ctx.repo.id,
          "--expires-at",
          at,
          "--on-expiry",
          @policy,
          "--no-wait"
        ])

      complete(ctx.box, create)
      assert %{"at" => reported, "action" => @policy} = json(ctx, ["env", "show", id])["expiry"]
      assert {:ok, parsed, 0} = DateTime.from_iso8601(reported)
      assert DateTime.compare(parsed, deadline) == :eq

      job =
        Repo.one!(
          from j in Oban.Job,
            where:
              j.worker == "Foreman.Jobs.EnvironmentExpiry" and j.args["environment_id"] == ^id
        )

      assert DateTime.to_unix(job.scheduled_at) ==
               DateTime.to_unix(Repo.get!(Environment, id).expiry_at)

      # Advance just this fixture's deadline, then execute the actual scheduled worker.
      Repo.get!(Environment, id)
      |> change(expiry_at: DateTime.add(DateTime.utc_now(), -1))
      |> Repo.update!()

      assert :ok = Foreman.Jobs.EnvironmentExpiry.perform(job)

      [cleanup] =
        json(ctx, ["op", "list", id]) |> items() |> Enum.filter(&(&1["trigger"] == "expiry"))

      assert cleanup["action"] == @policy
      complete(ctx.box, cleanup["id"])
      assert json(ctx, ["op", "show", cleanup["id"]])["status"] == "succeeded"

      if @policy == "stop" do
        assert json(ctx, ["env", "show", id])["observed_state"] == "stopped"
      else
        assert [] == json(ctx, ["env", "list"]) |> items()
      end
    end
  end

  defp log_pages(ctx, op, extra) do
    ctx
    |> launch(["--json", "op", "logs", op, "--follow" | extra])
    |> finish()
    |> success()
    |> decode_pages()
  end

  defp decode_pages(output),
    do: output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp sample(box, id, ids),
    do: event(box, "box.workspaces", %{since_join_ms: 0, environments: %{id => ids}})

  defp complete(box, id),
    do:
      event(box, "op.result", %{op_id: id, status: "ok", result: %{"container_id" => "workspace"}})

  defp event(box, type, payload) do
    {:ok, event} = Event.new(type, payload)
    assert :ok = Agents.handle_event(box.id, event)
  end
end
