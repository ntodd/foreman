defmodule Foreman.TokenRotationTest do
  # Refreshing a user's GitHub token rotates it: GitHub revokes the old
  # one, which other environments of the user may still hold.
  use Foreman.DataCase
  use Oban.Testing, repo: Foreman.Repo

  import Mox

  alias Foreman.GitHub
  alias Foreman.GitHub.ClientMock

  setup :verify_on_exit!

  setup do
    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:foreman, :github_app) end)

    user =
      user_fixture(
        access_token: "ghu_old",
        refresh_token: "ghr_old",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 4 * 3600)
      )

    %{user: user, repo: repo_fixture(token_mode: "broad")}
  end

  defp rotates do
    expect(ClientMock, :refresh_user_token, fn _, "ghr_old" ->
      {:ok,
       %{
         access_token: "ghu_new",
         refresh_token: "ghr_new",
         expires_in: 28_800,
         refresh_token_expires_in: 15_000_000
       }}
    end)
  end

  test "an environment still building when the token rotates gets the new one", %{
    user: user,
    repo: repo
  } do
    box = box_fixture(owner_user_id: user.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    building = environment_fixture(user: user, repo: repo, box: box, created_once: false)

    op =
      Foreman.Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: building.id,
        box_id: box.id,
        action: "create",
        command: "env.create",
        status: "dispatched",
        dispatched_at: DateTime.utc_now(),
        args: %{"token" => true}
      })

    rotates()
    assert {:ok, "ghu_new"} = GitHub.environment_token(user, repo)
    assert :ok = perform_job(Foreman.Jobs.PushTokens, %{user_id: user.id})

    {:ok, ev} = ForemanProtocol.Event.new("op.result", %{op_id: op.id, status: "ok", result: %{}})
    :ok = Foreman.Agents.handle_event(box.id, ev)

    assert Repo.exists?(
             from o in Foreman.Operations.Operation,
               where: o.environment_id == ^building.id and o.action == "secrets_write"
           )
  end

  test "rotating a user's token sends their other environments the new one", %{
    user: user,
    repo: repo
  } do
    # B was handed the user token two hours ago; A's refresh now rotates it.
    b =
      environment_fixture(user: user, repo: repo)
      |> Ecto.Changeset.change(token_pushed_at: DateTime.add(DateTime.utc_now(), -2 * 3600))
      |> Repo.update!()

    rotates()
    assert {:ok, "ghu_new"} = GitHub.environment_token(user, repo)

    assert_enqueued(worker: Foreman.Jobs.PushTokens, args: %{user_id: user.id})
    assert :ok = perform_job(Foreman.Jobs.PushTokens, %{user_id: user.id})

    assert Repo.exists?(
             from o in Foreman.Operations.Operation,
               where: o.environment_id == ^b.id and o.action == "secrets_write"
           )
  end

  test "a deferred token write waits behind a queued first create", %{user: user, repo: repo} do
    env = environment_fixture(user: user, repo: repo, created_once: false)

    op =
      Foreman.Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: env.id,
        box_id: env.box_id,
        action: "create",
        command: "env.create",
        status: "queued",
        args: %{}
      })

    assert :ok = perform_job(Foreman.Jobs.PushTokens, %{user_id: user.id})
    assert Foreman.Operations.next_queued(env.id, false).id == op.id
    assert Foreman.Operations.next_queued(env.id, true).action == "secrets_write"
  end

  test "a token that's still fresh isn't rotated, and nothing is pushed", %{user: user} do
    user =
      user
      |> Ecto.Changeset.change(
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 7 * 3600)
      )
      |> Repo.update!()

    assert {:ok, "ghu_old"} = GitHub.user_token(user, 5 * 3600)
    refute_enqueued(worker: Foreman.Jobs.PushTokens)
  end
end
