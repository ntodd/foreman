defmodule ForemanWeb.AttachmentAPITest do
  @moduledoc """
  Attaching a file through the public API: as an environment's box relays
  it, which is how `gh --attach` in an environment reaches it, and with a
  bearer token that was granted the action.
  """
  use ForemanWeb.ConnCase

  import Foreman.PublicAPIMutationFixtures
  import Mox

  alias Foreman.{OAuth, Repo}
  alias Foreman.Attachments.Upload
  alias Foreman.GitHub.ClientMock
  alias ForemanProtocol.Auth

  @relay "/api/agents/relay/v1"

  setup :local_git
  setup :verify_on_exit!

  setup do
    user = user_fixture()

    owner =
      owner_fixture(login: "acme")
      |> Ecto.Changeset.change(attachment_token: "github_pat_bot")
      |> Repo.update!()

    repo =
      repo_fixture(owner: owner, name: "storefront")
      |> Ecto.Changeset.change(private: false, github_id: 1001)
      |> Repo.update!()

    box = box_fixture(owner_user_id: user.id, vm: %{"ready" => true})
    env = environment_fixture(user: user, repo: repo, box: box)
    sibling = environment_fixture(user: user, repo: repo, box: box)

    # GitHub says the repository is the acting user's to push to.
    stub(ClientMock, :get_repo, fn _token, "acme/storefront" ->
      {:ok, %{"id" => 1001, "permissions" => %{"push" => true}}}
    end)

    %{user: user, repo: repo, box: box, env: env, sibling: sibling}
  end

  # A request as the environment's box signs and sends it.
  defp relay(ctx, method, path, body) do
    raw = JSON.encode!(body)
    target = @relay <> path

    headers =
      Auth.relay_headers(ctx.box.id, ctx.box.__private_key__, %{
        environment: ctx.env.id,
        method: method,
        target: target,
        body: raw,
        idempotency_key: nil
      })

    headers
    |> Enum.reduce(ctx.conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, target, raw)
  end

  defp bearer(ctx, scopes, method, path, body) do
    {actor, grant} = principal(ctx.user, scopes)
    token = OAuth.issue(grant, actor.scopes, :user).access_token

    %{ctx.conn | remote_ip: {127, 0, 0, 1}}
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, "/api/v1" <> path, JSON.encode!(body))
  end

  describe "from inside the environment" do
    test "a file goes up in chunks and comes back as its asset's URL", ctx do
      path = "/environments/#{ctx.env.id}/attachments"

      # One full chunk, as large as a box will relay, and two bytes more.
      head = :binary.copy("a", Foreman.Attachments.chunk_size())
      size = byte_size(head) + 2

      opened = relay(ctx, "POST", path, %{name: "login.png", size: size, repository_id: 1001})

      assert %{"id" => id, "chunk_size" => chunk, "received" => 0} = json_response(opened, 201)
      assert chunk == byte_size(head)

      body = %{offset: 0, data: Base.encode64(head)}
      assert byte_size(JSON.encode!(body)) <= 900_000
      first = relay(ctx, "PATCH", "#{path}/#{id}", body)
      assert json_response(first, 200) == %{"received" => chunk}

      whole = head <> "de"

      expect(ClientMock, :upload_attachment, fn "github_pat_bot",
                                                1001,
                                                "login.png",
                                                "image/png",
                                                ^whole ->
        {:ok, "https://github.com/user-attachments/assets/5b8ee541"}
      end)

      last = relay(ctx, "PATCH", "#{path}/#{id}", %{offset: chunk, data: Base.encode64("de")})

      assert json_response(last, 200) == %{
               "received" => size,
               "url" => "https://github.com/user-attachments/assets/5b8ee541"
             }

      assert Repo.all(Upload) == []
    end

    test "reaches no environment but its own", ctx do
      path = "/environments/#{ctx.sibling.id}/attachments"

      assert %{"code" => "resource_not_found"} =
               json_response(relay(ctx, "POST", path, %{name: "a.png", size: 1}), 404)
    end

    test "says what is wrong with a request, by status", ctx do
      path = "/environments/#{ctx.env.id}/attachments"

      assert %{"code" => "invalid_request"} =
               json_response(relay(ctx, "POST", path, %{name: "notes.txt", size: 1}), 422)

      %{"id" => id} = json_response(relay(ctx, "POST", path, %{name: "a.png", size: 2}), 201)

      assert %{"code" => "attachment_offset_mismatch"} =
               json_response(
                 relay(ctx, "PATCH", "#{path}/#{id}", %{offset: 1, data: "AQ=="}),
                 409
               )

      expect(ClientMock, :upload_attachment, fn _, _, _, _, _ ->
        {:error, {:http, 404, "Not Found"}}
      end)

      assert %{"code" => "attachment_upload_failed", "message" => message} =
               json_response(
                 relay(ctx, "PATCH", "#{path}/#{id}", %{offset: 0, data: Base.encode64("ab")}),
                 502
               )

      assert message =~ "write access"

      assert %{"code" => "resource_not_found"} =
               json_response(
                 relay(ctx, "PATCH", "#{path}/#{Ecto.UUID.generate()}", %{offset: 0, data: "AQ=="}),
                 404
               )
    end

    test "is forbidden to someone who can't write to the repository themselves", ctx do
      stub(ClientMock, :get_repo, fn _token, _name ->
        {:ok, %{"id" => 1001, "permissions" => %{"push" => false}}}
      end)

      path = "/environments/#{ctx.env.id}/attachments"

      assert %{"code" => "forbidden", "message" => message} =
               json_response(relay(ctx, "POST", path, %{name: "a.png", size: 1}), 403)

      assert message =~ "write access"

      stub(ClientMock, :get_repo, fn _token, _name -> {:error, {:http, 502, nil}} end)

      assert %{"code" => "repository_access_unavailable"} =
               json_response(relay(ctx, "POST", path, %{name: "a.png", size: 1}), 503)
    end

    test "is unavailable, and says so, when the owner has no attachment token", ctx do
      ctx.repo.owner |> Ecto.Changeset.change(attachment_token: nil) |> Repo.update!()
      path = "/environments/#{ctx.env.id}/attachments"

      assert %{"code" => "attachments_unavailable", "message" => message} =
               json_response(relay(ctx, "POST", path, %{name: "a.png", size: 1}), 409)

      assert message =~ "acme"
    end

    test "is refused past what one environment may hold at once", ctx do
      path = "/environments/#{ctx.env.id}/attachments"
      size = Foreman.Attachments.max_video_bytes()

      for _ <- 1..div(Foreman.Attachments.max_pending_bytes(), size),
          do: json_response(relay(ctx, "POST", path, %{name: "a.mp4", size: size}), 201)

      assert %{"code" => "too_many_attachments"} =
               json_response(relay(ctx, "POST", path, %{name: "a.mp4", size: size}), 429)
    end
  end

  describe "with a bearer token" do
    test "a connection granted the action attaches to its user's environment", ctx do
      path = "/environments/#{ctx.env.id}/attachments"
      opened = bearer(ctx, ~w(attachments:create), "POST", path, %{name: "a.png", size: 1})

      assert %{"id" => _} = json_response(opened, 201)
    end

    test "a connection without it is refused whatever it names", ctx do
      scopes = ~w(environments:read secrets:write)

      for {method, path, body} <- [
            {"POST", "/environments/#{ctx.env.id}/attachments", %{name: "a.png", size: 1}},
            {"POST", "/environments/#{Ecto.UUID.generate()}/attachments",
             %{name: "a.png", size: 1}},
            {"PATCH", "/environments/#{ctx.env.id}/attachments/#{Ecto.UUID.generate()}",
             %{offset: 0, data: "AQ=="}}
          ] do
        assert %{"code" => "insufficient_scope"} =
                 json_response(bearer(ctx, scopes, method, path, body), 403)
      end
    end
  end

  test "an environment's connection carries the action, a service account can't be given it" do
    assert "attachments:create" in OAuth.Scopes.environment()
    assert "attachments:create" in OAuth.Scopes.all()
    refute "attachments:create" in OAuth.Scopes.service()
  end
end
