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
