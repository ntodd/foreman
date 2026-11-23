defmodule ForemanWeb.SecretAPITest do
  @moduledoc "Listing and changing secrets through the public API."
  use ForemanWeb.ConnCase

  import Foreman.PublicAPIMutationFixtures

  alias Foreman.{OAuth, Repo, Scope, Secrets}
  alias Foreman.Secrets.Secret

  @scopes ~w(secrets:list secrets:write)

  setup :local_git
  setup %{conn: conn}, do: %{conn: %{conn | remote_ip: {127, 0, 0, 1}}}

  setup do
    user = user_fixture()
    admin = user_fixture(role: "admin")
    repo = repo_fixture() |> Ecto.Changeset.change(private: false) |> Repo.update!()
    box = box_fixture(owner_user_id: user.id)
    env = environment_fixture(user: user, repo: repo, box: box)

    %{user: user, admin: admin, repo: repo, env: env, owner: repo.owner, box: box}
  end

  defp token(user, scopes \\ @scopes) do
    {actor, grant} = principal(user, scopes)
    OAuth.issue(grant, actor.scopes, :user).access_token
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp list(conn, token, path, params \\ %{}),
    do: conn |> authed(token) |> get("/api/v1/secrets/" <> path, params)

  defp change(conn, token, path, body) do
    conn
    |> authed(token)
    |> put_req_header("content-type", "application/json")
    |> patch("/api/v1/secrets/" <> path, JSON.encode!(body))
  end

  defp set(pairs), do: for({name, value} <- pairs, do: %{name: name, value: value})

  describe "changing an environment's secrets" do
    test "sets and removes in one request, and never returns a value", ctx do
      u = Scope.for_user(ctx.user)
      {:ok, _} = Secrets.put_secret(u, "environment", ctx.env, %{"name" => "OLD", "value" => "1"})
      token = token(ctx.user)
      path = "environment/#{ctx.env.id}"

      reply =
        change(ctx.conn, token, path, %{
          secrets: set([{"A", "one"}, {"B", "two words"}]),
          unset: ["OLD", "NEVER_SET"]
        })

      assert %{"set" => ["A", "B"], "unset" => ["OLD"]} = json_response(reply, 200)
      refute reply.resp_body =~ "two words"
      assert Secrets.resolve(ctx.env) == %{"A" => "one", "B" => "two words"}

      listed = json_response(list(ctx.conn, token, path), 200)

      assert %{"items" => [%{"name" => "A"} = item, %{"name" => "B"}], "next_cursor" => nil} =
               listed

      assert Map.keys(item) |> Enum.sort() == ["name", "updated_at"]
    end

    test "says which of the caller's environments now wait on a restart", ctx do
      env =
        ctx.env
        |> Ecto.Changeset.change(
          applied_secret_hashes: %{},
          pending_restart: false,
          pending_changes: []
        )
        |> Repo.update!()

      reply =
        change(ctx.conn, token(ctx.user), "environment/#{env.id}", %{secrets: set([{"A", "1"}])})

      assert %{
               "pending_restart" => [%{"id" => id, "slug" => slug}],
               "others_pending_restart" => 0
             } =
               json_response(reply, 200)

      assert {id, slug} == {env.id, env.slug}
    end

    test "is all or nothing, and names the secret that was refused", ctx do
      path = "environment/#{ctx.env.id}"
      body = %{secrets: set([{"A", "1"}, {"FOREMAN_TOKEN", "x"}])}
      reply = change(ctx.conn, token(ctx.user), path, body)

      assert %{"code" => "invalid_request", "message" => message} = json_response(reply, 422)
      assert message =~ "FOREMAN_TOKEN"
      assert message =~ "reserves"
      assert Repo.aggregate(Secret, :count) == 0
    end

    test "another person's environment is not found, even for an admin", ctx do
      path = "environment/#{ctx.env.id}"
      body = %{secrets: set([{"A", "1"}])}

      for other <- [user_fixture(), ctx.admin] do
        assert json_response(change(ctx.conn, token(other), path, body), 404)["code"] ==
                 "resource_not_found"

        assert json_response(list(ctx.conn, token(other), path), 404)["code"] ==
                 "resource_not_found"
      end

      assert Repo.aggregate(Secret, :count) == 0
    end

    test "records the client that made the change", ctx do
      change(ctx.conn, token(ctx.user), "environment/#{ctx.env.id}", %{secrets: set([{"A", "1"}])})

      assert [%{action: "secret.create", metadata: metadata}] = Foreman.Audit.recent()
      assert %{"client_id" => "foreman-cli", "actor_kind" => "user", "name" => "A"} = metadata
    end
  end

  describe "the caller's own secrets" do
    test "are addressed as me or by the caller's own id", ctx do
      token = token(ctx.user)

      assert %{"set" => ["MINE"]} =
               json_response(
                 change(ctx.conn, token, "user/me", %{secrets: set([{"MINE", "1"}])}),
                 200
               )

      for subject <- ["me", ctx.user.id] do
        assert %{"items" => [%{"name" => "MINE"}]} =
                 json_response(list(ctx.conn, token, "user/#{subject}"), 200)
      end

      assert %{user_id: user_id} = Repo.get_by!(Secret, name: "MINE")
      assert user_id == ctx.user.id
    end

    test "someone else's are not found", ctx do
      assert json_response(list(ctx.conn, token(ctx.user), "user/#{ctx.admin.id}"), 404)["code"] ==
               "resource_not_found"
    end
  end

  describe "repository and owner secrets" do
    test "an admin changes a repository's", ctx do
      token = token(ctx.admin)
      path = "repo/#{ctx.repo.id}"

      assert %{"set" => ["SHARED"], "others_pending_restart" => others} =
               json_response(
                 change(ctx.conn, token, path, %{secrets: set([{"SHARED", "1"}])}),
                 200
               )

      assert is_integer(others)
      assert Secrets.resolve(ctx.env) == %{"SHARED" => "1"}

      assert %{"items" => [%{"name" => "SHARED"}]} =
               json_response(list(ctx.conn, token, path), 200)
    end

    test "an admin changes an owner's, by login or id", ctx do
      token = token(ctx.admin)

      for {subject, name} <- [{ctx.owner.login, "BY_LOGIN"}, {ctx.owner.id, "BY_ID"}] do
        reply = change(ctx.conn, token, "owner/#{subject}", %{secrets: set([{name, "1"}])})
        assert %{"set" => [^name]} = json_response(reply, 200)
      end

      assert Secrets.resolve(ctx.env) == %{"BY_LOGIN" => "1", "BY_ID" => "1"}
    end

    test "a member is refused, whether or not the subject exists", ctx do
      token = token(ctx.user)
      body = %{secrets: set([{"A", "1"}])}

      for path <- ["repo/#{ctx.repo.id}", "owner/#{ctx.owner.login}", "owner/nobody-by-this-name"] do
        assert %{"code" => "forbidden"} = json_response(change(ctx.conn, token, path, body), 403)
        assert %{"code" => "forbidden"} = json_response(list(ctx.conn, token, path), 403)
      end

      assert Repo.aggregate(Secret, :count) == 0
    end

    test "an admin gets not found for a repository or owner that isn't there", ctx do
      token = token(ctx.admin)

      for path <- ["repo/#{Ecto.UUID.generate()}", "repo/not-a-uuid", "owner/nobody-by-this-name"] do
        assert json_response(list(ctx.conn, token, path), 404)["code"] == "resource_not_found"
      end
    end
  end

  describe "permissions on the connection" do
    test "listing and changing are separate scopes", ctx do
      path = "environment/#{ctx.env.id}"
      body = %{secrets: set([{"A", "1"}])}

      read_only = token(ctx.user, ["secrets:list"])

      assert json_response(change(ctx.conn, read_only, path, body), 403)["code"] ==
               "insufficient_scope"

      assert json_response(list(ctx.conn, read_only, path), 200)

      write_only = token(ctx.user, ["secrets:write"])
      assert json_response(list(ctx.conn, write_only, path), 403)["code"] == "insufficient_scope"
      assert json_response(change(ctx.conn, write_only, path, body), 200)

      neither = token(ctx.user, ["environments:list"])

      assert json_response(change(ctx.conn, neither, path, body), 403)["code"] ==
               "insufficient_scope"
    end

    test "a missing or invalid token is unauthorized", ctx do
      assert json_response(get(ctx.conn, "/api/v1/secrets/user/me"), 401)["code"] ==
               "invalid_token"
    end

    test "a service account cannot be granted or use the secret scopes", ctx do
      refute "secrets:list" in OAuth.Scopes.service()
      refute "secrets:write" in OAuth.Scopes.service()
      assert "secrets:write" in OAuth.Scopes.all()

      admin = Scope.for_user(ctx.admin)

      for scope <- @scopes do
        attrs = %{"name" => "CI", "scopes" => ["repos:list", scope]}
        assert {:error, _} = OAuth.ServiceAccounts.register(admin, "service", attrs)
      end

      assert {:ok, _} =
               OAuth.ServiceAccounts.register(admin, "service", %{
                 "name" => "CI",
                 "scopes" => ["repos:list"]
               })

      service = %OAuth.Principal{
        user: ctx.user,
        kind: :service_account,
        client_id: "svc",
        scopes: @scopes,
        grant_id: Ecto.UUID.generate()
      }

      conn = ctx.conn |> assign(:api_principal, service)

      reply =
        ForemanWeb.SecretMutationController.update(
          %{conn | body_params: %{"secrets" => [%{"name" => "A", "value" => "1"}]}},
          %{"scope" => "user", "subject" => "me"}
        )

      assert json_response(reply, 403)["code"] == "forbidden"
      assert Repo.aggregate(Secret, :count) == 0
    end
  end

  describe "authority that changes while a request is in flight" do
    # The principal is what authentication loaded; the database has moved on.
    defp stale(ctx, user, path_params, body) do
      {principal, grant} = principal(user, @scopes)
      conn = ctx.conn |> assign(:api_principal, principal)

      call = fn ->
        ForemanWeb.SecretMutationController.update(%{conn | body_params: body}, path_params)
      end

      {call, grant}
    end

    test "an admin demoted since authenticating cannot finish a repository change", ctx do
      body = %{"secrets" => [%{"name" => "A", "value" => "1"}]}

      for params <- [
            %{"scope" => "repo", "subject" => ctx.repo.id},
            %{"scope" => "owner", "subject" => ctx.owner.login}
          ] do
        admin = user_fixture(role: "admin")
        {call, _grant} = stale(ctx, admin, params, body)
        admin |> Ecto.Changeset.change(role: "member") |> Repo.update!()

        assert json_response(call.(), 403)["code"] == "forbidden"
      end

      assert Repo.aggregate(Secret, :count) == 0
    end

    test "a connection revoked since authenticating changes nothing", ctx do
      body = %{"secrets" => [%{"name" => "A", "value" => "1"}]}
      {call, grant} = stale(ctx, ctx.user, %{"scope" => "user", "subject" => "me"}, body)
      OAuth.revoke_grant(grant.id)

      assert json_response(call.(), 404)["code"] == "resource_not_found"
      assert Repo.aggregate(Secret, :count) == 0
    end

    test "an environment the caller can no longer reach is neither changed nor named", ctx do
      lender = user_fixture()
      shared = box_fixture(owner_user_id: lender.id, shared_user_ids: [ctx.user.id])

      env =
        environment_fixture(user: ctx.user, repo: ctx.repo, box: shared)
        |> Ecto.Changeset.change(
          applied_secret_hashes: %{},
          pending_restart: false,
          pending_changes: []
        )
        |> Repo.update!()

      shared |> Ecto.Changeset.change(shared_user_ids: []) |> Repo.update!()
      token = token(ctx.user)

      assert json_response(
               change(ctx.conn, token, "environment/#{env.id}", %{secrets: set([{"A", "1"}])}),
               404
             )

      # The caller's own secrets still reach it, but the response doesn't name it.
      reply = change(ctx.conn, token, "user/me", %{secrets: set([{"MINE", "1"}])})
      assert %{"pending_restart" => pending} = json_response(reply, 200)
      refute env.id in Enum.map(pending, & &1["id"])
      assert Repo.reload!(env).pending_restart
    end
  end

  describe "request validation" do
    test "rejects bodies that aren't a list of names and values", ctx do
      token = token(ctx.user)
      path = "environment/#{ctx.env.id}"

      bad = [
        %{},
        %{secrets: [], unset: []},
        %{secrets: %{"A" => "1"}},
        %{secrets: [%{name: "A"}]},
        %{secrets: [%{name: "A", value: 1}]},
        %{secrets: [%{name: "A", value: "1", extra: true}]},
        %{unset: [1]},
        %{unset: "A"},
        %{secrets: set([{"A", "1"}]), other: true},
        %{secrets: set([{"A", "1"}, {"A", "2"}])},
        %{secrets: set([{"A", "1"}]), unset: ["A"]},
        %{unset: Enum.map(1..101, &"N#{&1}")},
        %{unset: ["has space"]},
        %{unset: ["NUL\0BYTE"]},
        %{secrets: [%{name: "NUL\0BYTE", value: "1"}]},
        %{secrets: [%{name: "", value: "1"}]}
      ]

      for body <- bad do
        reply = change(ctx.conn, token, path, body)
        assert json_response(reply, 422)["code"] == "invalid_request", inspect(body)
      end

      assert Repo.aggregate(Secret, :count) == 0
    end

    test "an unknown kind of scope is not found", ctx do
      assert json_response(list(ctx.conn, token(ctx.user), "team/#{ctx.env.id}"), 404)["code"] ==
               "resource_not_found"
    end

    test "a name that isn't one is refused without being repeated back", ctx do
      body = %{secrets: [%{name: "sk live 4242 pasted in the wrong field", value: "1"}]}
      reply = change(ctx.conn, token(ctx.user), "user/me", body)

      assert %{"code" => "invalid_request"} = json_response(reply, 422)
      refute reply.resp_body =~ "4242"
    end

    test "values stay out of the request log, in a well-formed body or not" do
      params = %{"secrets" => [%{"name" => "A", "value" => "hunter2"}], "unset" => ["B"]}
      filtered = Phoenix.Logger.filter_values(params)

      refute inspect(filtered) =~ "hunter2"
      assert filtered["unset"] == ["B"]

      for misshapen <- [
            %{"name" => "A", "value" => "hunter2"},
            %{"x" => [%{"value" => "hunter2"}]}
          ] do
        refute inspect(Phoenix.Logger.filter_values(misshapen)) =~ "hunter2"
      end
    end
  end

  describe "listing" do
    test "pages by name", ctx do
      u = Scope.for_user(ctx.user)
      names = for n <- 1..51, do: "S" <> String.pad_leading(to_string(n), 3, "0")
      {:ok, _} = Secrets.apply_changes(u, "user", ctx.user, Enum.map(names, &{&1, "v"}), [])
      token = token(ctx.user)

      first = json_response(list(ctx.conn, token, "user/me"), 200)
      assert length(first["items"]) == 50
      assert is_binary(first["next_cursor"])

      rest = json_response(list(ctx.conn, token, "user/me", %{cursor: first["next_cursor"]}), 200)
      assert Enum.map(first["items"] ++ rest["items"], & &1["name"]) == names
      assert rest["next_cursor"] == nil
    end
  end
end
