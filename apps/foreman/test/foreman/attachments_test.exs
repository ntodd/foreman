defmodule Foreman.AttachmentsTest do
  use Foreman.DataCase

  import Foreman.PublicAPIMutationFixtures
  import Mox

  alias Foreman.{Attachments, Audit}
  alias Foreman.Attachments.Upload
  alias Foreman.GitHub.ClientMock
  alias Foreman.OAuth.EnvironmentConnection

  setup :local_git
  setup :verify_on_exit!

  setup do
    user = user_fixture()
    owner = owner_fixture(login: "acme") |> change(attachment_token: "github_pat_bot")
    owner = Repo.update!(owner)

    repo =
      repo_fixture(owner: owner, name: "storefront")
      |> change(private: false, github_id: 1001)
      |> Repo.update!()

    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    env = environment_fixture(user: user, repo: repo, box: box)
    {:ok, principal} = EnvironmentConnection.principal(box.id, env.id)

    # What GitHub says of the acting user and the repository, unless a
    # test says otherwise: it's theirs to push to.
    stub(ClientMock, :get_repo, fn _token, "acme/storefront" -> {:ok, github_repo(true)} end)

    %{user: user, owner: owner, repo: repo, box: box, env: env, principal: principal}
  end

  defp github_repo(push?), do: %{"id" => 1001, "permissions" => %{"push" => push?}}

  # A file of one full chunk and `tail` more bytes, and its two chunks.
  defp two_chunks(tail) do
    first = :binary.copy(<<7>>, Attachments.chunk_size())
    {byte_size(first) + byte_size(tail), first, tail}
  end

  defp start(ctx, params), do: Attachments.start(ctx.principal, ctx.env.id, params)

  defp append(ctx, id, offset, bytes),
    do:
      Attachments.append(ctx.principal, ctx.env.id, id, %{
        "offset" => offset,
        "data" => Base.encode64(bytes)
      })

  describe "start/3" do
    test "opens an upload and says how large a chunk may be", ctx do
      assert {:ok, %{id: id, chunk_size: chunk, received: 0}} =
               start(ctx, %{"name" => "login.png", "size" => 10})

      assert chunk == Attachments.chunk_size()

      assert %Upload{name: "login.png", content_type: "image/png", size: 10, received: 0} =
               upload = Repo.get!(Upload, id)

      assert upload.environment_id == ctx.env.id
      assert upload.repository_id == 1001
    end

    test "takes the environment's own repository when one is named", ctx do
      assert {:ok, _} = start(ctx, %{"name" => "a.png", "size" => 1, "repository_id" => 1001})

      assert {:error, :invalid_request, message} =
               start(ctx, %{"name" => "a.png", "size" => 1, "repository_id" => 2002})

      assert message =~ "acme/storefront"
    end

    test "is unavailable until the owner has an attachment token", ctx do
      ctx.owner |> change(attachment_token: nil) |> Repo.update!()

      assert {:error, :attachments_unavailable, message} =
               start(ctx, %{"name" => "a.png", "size" => 1})

      assert message =~ "acme"
    end

    test "is unavailable for a repository GitHub hasn't identified", ctx do
      ctx.repo |> change(github_id: nil) |> Repo.update!()
      ctx.env |> change(repo_github_id: nil) |> Repo.update!()

      assert {:error, :attachments_unavailable, _} = start(ctx, %{"name" => "a.png", "size" => 1})
    end

    test "takes images and video by their extension, whatever its case", ctx do
      for {name, type} <- [
            {"a.PNG", "image/png"},
            {"b.jpeg", "image/jpeg"},
            {"c.webm", "video/webm"},
            {"d.mov", "video/quicktime"},
            {"e.svg", "image/svg+xml"}
          ] do
        assert {:ok, %{id: id}} = start(ctx, %{"name" => name, "size" => 1})
        assert Repo.get!(Upload, id).content_type == type
      end

      for name <- ["notes.txt", "archive.zip", "png", ".png/../x"] do
        assert {:error, :invalid_request, _} = start(ctx, %{"name" => name, "size" => 1})
      end
    end

    test "refuses a file over the limit for its kind, and an empty one", ctx do
      assert {:ok, _} = start(ctx, %{"name" => "a.png", "size" => Attachments.max_image_bytes()})

      assert {:error, :invalid_request, message} =
               start(ctx, %{"name" => "a.png", "size" => Attachments.max_image_bytes() + 1})

      assert message =~ "10 MB"

      assert {:error, :invalid_request, _} =
               start(ctx, %{"name" => "a.mp4", "size" => Attachments.max_video_bytes() + 1})

      assert {:error, :invalid_request, _} = start(ctx, %{"name" => "a.png", "size" => 0})
    end

    test "refuses input that isn't a name and a size", ctx do
      for params <- [
            %{},
            %{"name" => "a.png"},
            %{"name" => 7, "size" => 1},
            %{"name" => "a.png", "size" => "1"},
            %{"name" => "a.png", "size" => 1, "content_type" => "text/html"},
            %{"name" => "a.png", "size" => 1, "repository_id" => "1001"},
            %{"name" => String.duplicate("a", 300) <> ".png", "size" => 1},
            %{"name" => "a\nb.png", "size" => 1}
          ] do
        assert {:error, :invalid_request, _} = start(ctx, params)
      end
    end

    test "reaches the connection's own environment and no other", ctx do
      sibling = environment_fixture(user: ctx.user, repo: ctx.repo, box: ctx.box)
      stranger = environment_fixture(repo: ctx.repo)

      for env <- [sibling, stranger] do
        assert {:error, :resource_not_found, _} =
                 Attachments.start(ctx.principal, env.id, %{"name" => "a.png", "size" => 1})
      end

      assert {:error, :resource_not_found, _} =
               Attachments.start(ctx.principal, "nonsense", %{"name" => "a.png", "size" => 1})
    end

    test "holds only so much at once for one environment", ctx do
      size = Attachments.max_video_bytes()
      open = div(Attachments.max_pending_bytes(), size)

      for _ <- 1..open, do: assert({:ok, _} = start(ctx, %{"name" => "a.mp4", "size" => size}))

      assert {:error, :too_many_attachments, _} = start(ctx, %{"name" => "a.mp4", "size" => size})
    end

    test "holds only so many at once, however small", ctx do
      for _ <- 1..Attachments.max_open(),
          do: assert({:ok, _} = start(ctx, %{"name" => "a.png", "size" => 1}))

      assert {:error, :too_many_attachments, _} = start(ctx, %{"name" => "a.png", "size" => 1})
    end

    test "forgets the environment's abandoned uploads first", ctx do
      size = Attachments.max_video_bytes()
      open = div(Attachments.max_pending_bytes(), size)
      for _ <- 1..open, do: {:ok, _} = start(ctx, %{"name" => "a.mp4", "size" => size})

      long_ago = DateTime.add(DateTime.utc_now(), -3600)
      Repo.update_all(Upload, set: [updated_at: long_ago])

      assert {:ok, %{id: id}} = start(ctx, %{"name" => "a.mp4", "size" => size})
      assert [%Upload{id: ^id}] = Repo.all(Upload)
    end
  end

  describe "who may attach" do
    test "takes the acting user's own write access to the repository", ctx do
      for {answer, code, said} <- [
            {{:ok, github_repo(false)}, :forbidden, "write access to acme/storefront"},
            {{:ok, %{"id" => 1001}}, :forbidden, "write access to acme/storefront"},
            # Another repository has taken the name.
            {{:ok, %{"id" => 2002, "permissions" => %{"push" => true}}}, :forbidden,
             "write access"},
            {{:error, :not_found}, :forbidden, "write access"},
            {{:error, {:http, 503, nil}}, :repository_access_unavailable, "Try again"}
          ] do
        stub(ClientMock, :get_repo, fn _token, "acme/storefront" -> answer end)

        assert {:error, ^code, message} = start(ctx, %{"name" => "a.png", "size" => 1})
        assert message =~ said
      end

      assert Repo.all(Upload) == []
    end

    test "asks GitHub as the user, with the user's own token", ctx do
      token = ctx.user.access_token

      expect(ClientMock, :get_repo, fn ^token, "acme/storefront" -> {:ok, github_repo(true)} end)

      assert {:ok, _} = start(ctx, %{"name" => "a.png", "size" => 1})
    end

    test "is asked again before the file goes to GitHub", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 1})
      stub(ClientMock, :get_repo, fn _token, _name -> {:ok, github_repo(false)} end)

      assert {:error, :forbidden, _} = append(ctx, id, 0, <<1>>)
      assert Repo.all(Upload) == []
    end
  end

  describe "append/4" do
    test "takes the file in order and uploads it when the last chunk arrives", ctx do
      {size, first, tail} = two_chunks(<<5, 6>>)
      {:ok, %{id: id}} = start(ctx, %{"name" => "login.png", "size" => size})

      assert {:ok, %{received: received} = partial} = append(ctx, id, 0, first)
      assert received == byte_size(first)
      refute Map.has_key?(partial, :url)

      whole = first <> tail

      expect(ClientMock, :upload_attachment, fn "github_pat_bot",
                                                1001,
                                                "login.png",
                                                "image/png",
                                                ^whole ->
        {:ok, "https://github.com/user-attachments/assets/5b8ee541"}
      end)

      assert {:ok, %{received: ^size, url: "https://github.com/user-attachments/assets/5b8ee541"}} =
               append(ctx, id, byte_size(first), tail)

      assert Repo.all(Upload) == []
      assert Repo.aggregate(Foreman.Attachments.Chunk, :count) == 0
    end

    test "audits the upload with who and what, and never the bytes", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "login.png", "size" => 2})
      expect(ClientMock, :upload_attachment, fn _, _, _, _, _ -> {:ok, "https://x.test/a"} end)
      {:ok, _} = append(ctx, id, 0, <<1, 2>>)

      assert [event] = Enum.filter(Audit.recent(), &(&1.action == "environment.attachment"))
      assert event.actor_id == ctx.user.id
      assert event.subject_id == ctx.env.id

      assert %{
               "name" => "login.png",
               "size" => 2,
               "repository" => "acme/storefront",
               "url" => "https://x.test/a",
               "client_id" => "foreman-environment"
             } = event.metadata
    end

    test "refuses a chunk out of order and keeps what it had", ctx do
      {size, first, _tail} = two_chunks(<<5, 6>>)
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => size})
      {:ok, %{received: received}} = append(ctx, id, 0, first)

      for offset <- [0, received + 1, -1] do
        assert {:error, :attachment_offset_mismatch, message} = append(ctx, id, offset, <<9>>)
        assert message =~ "offset #{received}"
      end

      assert Repo.get!(Upload, id).received == received
    end

    test "takes full chunks until the one that completes the file", ctx do
      {size, _first, _tail} = two_chunks(<<5, 6>>)
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => size})

      # A file sent a byte at a time would be a row a byte.
      assert {:error, :invalid_request, message} = append(ctx, id, 0, <<1, 2, 3>>)
      assert message =~ "#{Attachments.chunk_size()} bytes"
      assert Repo.get!(Upload, id).received == 0
      assert Repo.aggregate(Foreman.Attachments.Chunk, :count) == 0
    end

    test "refuses bytes past the size it was opened with", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 3})
      assert {:error, :invalid_request, _} = append(ctx, id, 0, <<1, 2, 3, 4>>)
      assert Repo.get!(Upload, id).received == 0
    end

    test "refuses a chunk that isn't base64, is too large or is empty", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.mp4", "size" => Attachments.chunk_size() * 2})
      params = fn data -> %{"offset" => 0, "data" => data} end
      over = Base.encode64(:binary.copy(<<0>>, Attachments.chunk_size() + 1))

      for data <- ["not base64!", over, "", 7] do
        assert {:error, :invalid_request, _} =
                 Attachments.append(ctx.principal, ctx.env.id, id, params.(data))
      end

      assert {:error, :invalid_request, _} =
               Attachments.append(ctx.principal, ctx.env.id, id, %{"data" => "AA=="})
    end

    test "says what GitHub refused, and lets the upload go", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 2})

      expect(ClientMock, :upload_attachment, fn _, _, _, _, _ ->
        {:error, {:http, 404, "Not Found"}}
      end)

      assert {:error, :attachment_upload_failed, message} = append(ctx, id, 0, <<1, 2>>)
      assert message =~ "write access to acme/storefront"

      # Nothing is held for a file GitHub didn't take: sending it again
      # is a new upload, and there is no second way to send this one.
      assert Repo.all(Upload) == []
      assert Repo.aggregate(Foreman.Attachments.Chunk, :count) == 0
      assert {:error, :resource_not_found, _} = append(ctx, id, 2, <<>>)
    end

    test "names a rejected token and a GitHub outage apart", ctx do
      for {error, expected} <- [
            {{:http, 401, "Bad credentials"}, "rejected the attachment token"},
            {{:http, 422, "File is too big"}, "File is too big"},
            {{:http, 403, "Forbidden"}, "GitHub refused the upload"},
            # Something in front of GitHub can answer for it after passing
            # the file on, so a server's failure says nothing either way.
            {{:http, 504, nil}, "may or may not"},
            # No answer at all: GitHub may have the file.
            {%RuntimeError{message: "timeout"}, "may or may not"},
            # An answer that it has the file, and nothing to reference it by.
            {:no_asset_url, "named no asset"}
          ] do
        {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 1})
        expect(ClientMock, :upload_attachment, fn _, _, _, _, _ -> {:error, error} end)

        assert {:error, :attachment_upload_failed, message} = append(ctx, id, 0, <<1>>)
        assert message =~ expected
        # Whatever happened, this upload is over.
        refute message =~ "Try again"
      end
    end

    test "says to send the file again when the last check couldn't be made", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 1})
      stub(ClientMock, :get_repo, fn _token, _name -> {:error, {:http, 502, nil}} end)

      # Before an upload opens the same failure says to try again. Here
      # there is nothing left to try again with.
      assert {:error, :repository_access_unavailable, message} = append(ctx, id, 0, <<1>>)
      assert message =~ "Send the file again"
      assert Repo.all(Upload) == []
    end

    test "takes no more of a file once its environment isn't the caller's to reach", ctx do
      owner = user_fixture()
      shared = box_fixture(owner_user_id: owner.id, shared_user_ids: [ctx.user.id])
      env = environment_fixture(user: ctx.user, repo: ctx.repo, box: shared)
      {personal, _grant} = principal(ctx.user, ~w(attachments:create))
      {size, first, tail} = two_chunks(<<5>>)
      {:ok, %{id: id}} = Attachments.start(personal, env.id, %{"name" => "a.png", "size" => size})

      send_chunk = fn offset, bytes ->
        Attachments.append(personal, env.id, id, %{
          "offset" => offset,
          "data" => Base.encode64(bytes)
        })
      end

      share = fn users ->
        Repo.update_all(from(b in Foreman.Boxes.Box, where: b.id == ^shared.id),
          set: [shared_user_ids: users]
        )
      end

      # The box stops being shared with them part way through.
      share.([])
      assert {:error, :resource_not_found, _} = send_chunk.(0, first)
      assert Repo.get!(Upload, id).received == 0

      share.([ctx.user.id])
      assert {:ok, _} = send_chunk.(0, first)

      # Or the repository leaves Foreman.
      ctx.repo |> change(removed_at: DateTime.utc_now()) |> Repo.update!()
      assert {:error, :resource_not_found, _} = send_chunk.(byte_size(first), tail)
    end

    test "takes nothing for an upload that has sat too long, pruned yet or not", ctx do
      {size, first, _tail} = two_chunks(<<5>>)
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => size})
      long_ago = DateTime.add(DateTime.utc_now(), -3600)
      Repo.update_all(Upload, set: [updated_at: long_ago])

      assert {:error, :resource_not_found, _} = append(ctx, id, 0, first)
      assert Repo.get!(Upload, id).received == 0
    end

    test "sends nothing when part of the file has gone missing", ctx do
      {size, first, tail} = two_chunks(<<5>>)
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => size})
      {:ok, _} = append(ctx, id, 0, first)
      Repo.delete_all(Foreman.Attachments.Chunk)

      # No upload_attachment is expected: Mox fails the test if it's called.
      assert {:error, :attachment_upload_failed, message} =
               append(ctx, id, byte_size(first), tail)

      assert message =~ "Send the file again"
      assert Repo.all(Upload) == []
    end

    test "holds nothing for a file whose sending was cut short", ctx do
      # GitHub can't be asked who may see the repository, which reading
      # the environment raises for (`Foreman.PublicAPI.Access`): an
      # answer, and one that doesn't say to try what is no longer there.
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 1})

      stub(ClientMock, :get_repo, fn _token, _name ->
        raise Foreman.PublicAPI.Access.Unavailable
      end)

      assert {:error, :repository_access_unavailable, message} = append(ctx, id, 0, <<1>>)
      assert message =~ "Send the file again"
      assert Repo.all(Upload) == []

      # Anything else that goes wrong is raised, and still holds nothing.
      stub(ClientMock, :get_repo, fn _token, _name -> {:ok, github_repo(true)} end)
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 1})
      stub(ClientMock, :get_repo, fn _token, _name -> raise "a bug" end)

      assert_raise RuntimeError, fn -> append(ctx, id, 0, <<1>>) end
      assert Repo.all(Upload) == []
      assert Repo.aggregate(Foreman.Attachments.Chunk, :count) == 0
    end

    test "finds no upload that isn't this environment's", ctx do
      other_user = user_fixture()
      other_box = box_fixture(owner_user_id: other_user.id, vm: %{"ready" => true})
      other = environment_fixture(user: other_user, repo: ctx.repo, box: other_box)
      {:ok, theirs} = EnvironmentConnection.principal(other_box.id, other.id)
      {:ok, %{id: id}} = Attachments.start(theirs, other.id, %{"name" => "a.png", "size" => 1})

      assert {:error, :resource_not_found, _} = append(ctx, id, 0, <<1>>)

      assert {:error, :resource_not_found, _} =
               Attachments.append(ctx.principal, other.id, id, %{"offset" => 0, "data" => "AQ=="})

      assert {:error, :resource_not_found, _} = append(ctx, Ecto.UUID.generate(), 0, <<1>>)
      assert {:error, :resource_not_found, _} = append(ctx, "nonsense", 0, <<1>>)
    end

    test "uploads nothing once the environment is destroyed", ctx do
      {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => 1})
      ctx.env |> change(destroyed_at: DateTime.utc_now()) |> Repo.update!()

      assert {:error, :resource_not_found, _} = append(ctx, id, 0, <<1>>)
    end
  end

  describe "what is stored" do
    test "chunks are encrypted, and aren't among the values a boot or a key change reads", ctx do
      {size, first, _tail} = two_chunks(<<5>>)
      {:ok, %{id: id}} = start(ctx, %{"name" => "b.png", "size" => size})
      {:ok, _} = append(ctx, id, 0, first)

      raw =
        Repo.one!(
          from c in "attachment_chunks",
            where: c.upload_id == type(^id, Ecto.UUID),
            select: c.data
        )

      refute raw == first
      refute :binary.match(raw, :binary.copy(<<7>>, 64)) != :nomatch
      assert {:ok, ^first} = Foreman.Vault.decrypt(raw)

      # Every encrypted column is read whole when the keys change. A file
      # in flight is megabytes, gone in minutes, and has no place there.
      refute Enum.any?(Foreman.Vault.encrypted_schemas(), fn {schema, _} ->
               schema == Foreman.Attachments.Chunk
             end)
    end

    test "a chunk the keys can't read is a lost one", ctx do
      {size, first, tail} = two_chunks(<<5>>)

      for unreadable <- ["not anything these keys wrote", <<1>>, ""] do
        {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => size})
        {:ok, _} = append(ctx, id, 0, first)
        Repo.update_all(Foreman.Attachments.Chunk, set: [data: unreadable])

        assert {:error, :attachment_upload_failed, message} =
                 append(ctx, id, byte_size(first), tail)

        assert message =~ "Send the file again"
      end
    end

    test "neither a file's bytes nor anything of the token reaches the query log", ctx do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
      secret = "bytes-of-a-private-screenshot"

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          {:ok, %{id: id}} = start(ctx, %{"name" => "a.png", "size" => byte_size(secret)})

          expect(ClientMock, :upload_attachment, fn _, _, _, _, _ -> {:ok, "https://x.test/a"} end)

          {:ok, _} = append(ctx, id, 0, secret)
        end)

      # The capture is live: the upload's own rows are in it.
      assert log =~ "attachment_uploads"
      refute log =~ secret
      refute log =~ Base.encode64(secret)
      refute log =~ "github_pat_bot"
    end
  end

  describe "prune/1" do
    test "drops uploads nothing has been sent to for a while, with their chunks", ctx do
      {size, first, _tail} = two_chunks(<<5>>)
      {:ok, %{id: stale}} = start(ctx, %{"name" => "a.png", "size" => size})
      {:ok, _} = append(ctx, stale, 0, first)
      {:ok, %{id: fresh}} = start(ctx, %{"name" => "b.png", "size" => 4})

      long_ago = DateTime.add(DateTime.utc_now(), -3600)
      Repo.update_all(from(u in Upload, where: u.id == ^stale), set: [updated_at: long_ago])

      Attachments.prune()

      assert [%Upload{id: ^fresh}] = Repo.all(Upload)
      assert Repo.aggregate(Foreman.Attachments.Chunk, :count) == 0
    end

    test "runs with the rest of the housekeeping", ctx do
      {:ok, %{id: _}} = start(ctx, %{"name" => "a.png", "size" => 4})
      long_ago = DateTime.add(DateTime.utc_now(), -3600)
      Repo.update_all(Upload, set: [updated_at: long_ago])

      assert :ok = Foreman.Jobs.Housekeeping.perform(%Oban.Job{})
      assert Repo.all(Upload) == []
    end
  end
end
