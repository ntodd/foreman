defmodule Foreman.AttachmentsConcurrencyTest do
  # These calls must commit, so each participant checks out its own ordinary
  # connection. A shared SQL Sandbox transaction cannot exercise this race.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Foreman.Fixtures
  import Foreman.PublicAPIMutationFixtures
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Foreman.{Attachments, Repo}
  alias Foreman.Attachments.Upload
  alias Foreman.Environments.Environment
  alias Foreman.GitHub.ClientMock
  alias Foreman.OAuth.EnvironmentConnection

  setup :local_git
  # The uploads open in tasks of their own.
  setup :set_mox_global

  setup do
    stub(ClientMock, :get_repo, fn _token, _name ->
      {:ok, %{"id" => 1001, "permissions" => %{"push" => true}}}
    end)

    Sandbox.unboxed_run(Repo, fn ->
      user = user_fixture()

      owner =
        owner_fixture()
        |> Ecto.Changeset.change(attachment_token: "github_pat_bot")
        |> Repo.update!()

      repo =
        repo_fixture(owner: owner)
        |> Ecto.Changeset.change(private: false, github_id: 1001)
        |> Repo.update!()

      box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
      env = environment_fixture(user: user, repo: repo, box: box)
      {:ok, principal} = EnvironmentConnection.principal(box.id, env.id)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from u in Upload, where: u.environment_id == ^env.id)
          Repo.delete_all(from g in Foreman.OAuth.Grant, where: g.user_id == ^user.id)
          Repo.delete_all(from e in Environment, where: e.id == ^env.id)
          Repo.delete!(Repo.reload!(box))
          Repo.delete!(Repo.reload!(repo))
          Repo.delete!(Repo.reload!(owner))
          Repo.delete!(Repo.reload!(user))
        end)
      end)

      %{env: env, principal: principal}
    end)
  end

  test "two uploads opened at once can't both take the room that is left", ctx do
    size = Attachments.max_video_bytes()

    open = fn ->
      Attachments.start(ctx.principal, ctx.env.id, %{"name" => "a.mp4", "size" => size})
    end

    # Room for exactly one more.
    Sandbox.unboxed_run(Repo, fn ->
      for _ <- 2..div(Attachments.max_pending_bytes(), size)//1, do: {:ok, _} = open.()
    end)

    parent = self()
    handler = make_ref()

    # Stop the first once it has counted what the environment holds, before
    # it adds its own. A second that could count now would see the same room.
    :ok =
      :telemetry.attach(
        handler,
        [:foreman, :repo, :query],
        fn _, _, meta, owner ->
          if meta.source == "attachment_uploads" and meta.query =~ "sum(" and
               Process.delete(:pause_after_count) do
            send(owner, {:counted, self()})

            receive do
              :carry_on -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(:pause_after_count, true)
          open.()
        end)
      end)

    assert_receive {:counted, first_pid}, 5_000
    second = Task.async(fn -> Sandbox.unboxed_run(Repo, open) end)

    # The second waits its turn for the environment.
    assert Task.yield(second, 300) == nil
    send(first_pid, :carry_on)

    assert {:ok, _} = Task.await(first)
    assert {:error, :too_many_attachments, _} = Task.await(second)

    Sandbox.unboxed_run(Repo, fn ->
      held = from u in Upload, where: u.environment_id == ^ctx.env.id, select: u.size
      assert Enum.sum(Repo.all(held)) == Attachments.max_pending_bytes()
    end)
  end
end
