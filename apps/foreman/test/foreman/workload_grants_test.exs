defmodule Foreman.WorkloadGrantsTest do
  use Foreman.DataCase
  import Mox

  alias Foreman.{Accounts, Environments, OAuth, Operations, Scope}
  alias Foreman.Environments.{Commands, Server}
  alias Foreman.OAuth.{Grant, ServiceAccounts}
  alias Foreman.Operations.Operation
  alias Foreman.GitHub.ClientMock
  alias ForemanProtocol.Command

  setup :verify_on_exit!

  setup do
    config(:git_base_url, "http://git.fixture")
    config(:github_app, %{})
    admin = user_fixture(role: "admin")
    owner = owner_fixture()

    repo =
      repo_fixture(owner: owner, token_mode: "broad", tailscale_tags: ["tag:repo"])
      |> save(private: false, manual: true, github_id: 101)

    extra = repo_fixture(owner: owner) |> save(private: false, manual: true, github_id: 102)
    hidden = repo_fixture(owner: owner) |> save(manual: true, github_id: 103)
    repo = save(repo, extra_repos: [extra.name, hidden.name])
    box = box_fixture(owner_user_id: admin.id)
    %{admin: admin, repo: repo, extra: extra, hidden: hidden, box: box}
  end

  test "service builds and refreshed files only contain approved material", ctx do
    approved = secret_fixture("repo", ctx.repo, "APPROVED", "approved-value")
    secret_fixture("owner", ctx.repo.owner, "OTHER", "owner-value")
    save(ctx.repo.owner, registry_username: "reader", registry_token: "registry-credential")
    {grant, user, env} = service(ctx, [approved.id])

    save(user,
      dotfiles_repository: "internal/private",
      devcontainer_features: %{"ghcr.io/org/feature:1" => %{}}
    )

    Repo.insert!(%Foreman.Prebuilds.Prebuild{
      repo_id: ctx.repo.id,
      box_id: ctx.box.id,
      branch: "main",
      config_path: ".devcontainer/devcontainer.json",
      status: "ready",
      repos: [ctx.repo.name, ctx.hidden.name]
    })

    github()
    config(:tailscale, %{client_id: "c", client_secret: "s", tags: ["tag:global"]})
    tags = grant.network_policy["tailscale_tags"]

    expect(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, p ->
      assert p.tags == tags
      {:ok, %{key: "tskey-auth-approved", id: "1"}}
    end)

    expect(ClientMock, :repo_read_token, 2, fn _, installation, names ->
      assert installation == ctx.repo.owner.installation_id
      assert names == {:ids, [ctx.repo.github_id, ctx.extra.github_id]}
      {:ok, "installation-read-only"}
    end)

    for action <- ~w(create secrets_write) do
      assert {:ok, cmd, _} = Commands.build(operation(env, grant, action), env)
      assert cmd.payload.files["github-token"] == "installation-read-only"
      assert cmd.payload.files["secrets.env"] =~ "approved-value"
      refute cmd.payload.files["secrets.env"] =~ "owner-value"
      refute Map.has_key?(cmd.payload, :registry_auth)

      if action == "create" do
        assert cmd.payload.tailscale.tags == tags
        refute Map.has_key?(cmd.payload, :dotfiles)
        refute Map.has_key?(cmd.payload, :features)
        refute Map.has_key?(cmd.payload, :prebuild_id)
      end
    end
  end

  test "a service cannot borrow a different installation's identity tag", ctx do
    {_, other, _} = service(ctx)

    assert {:error, :invalid_network_policy} =
             ServiceAccounts.register(Scope.for_user(ctx.admin), "service", %{
               "name" => "Second integration",
               "scopes" => ["environments:start"],
               "repo_ids" => [ctx.repo.id],
               "box_ids" => [ctx.box.id],
               "tailscale_tags" => [ServiceAccounts.identity_tag(other.id)]
             })
  end

  test "personal API tokens are scoped even on broad repos and include only readable secondary repos",
       ctx do
    user = ctx.admin
    {grant, env} = personal(ctx, user)
    github()

    stub(ClientMock, :get_repo, fn token, name ->
      assert token == user.access_token

      if name == ctx.hidden.full_name,
        do: {:error, :not_found},
        else:
          {:ok,
           %{"id" => if(name == ctx.repo.full_name, do: 101, else: 102), "full_name" => name}}
    end)

    expect(ClientMock, :scope_user_token, fn _, parent, _, names, _ ->
      assert parent == user.access_token
      assert names == {:ids, [ctx.repo.github_id, ctx.extra.github_id]}
      {:ok, %{token: "scoped-personal"}}
    end)

    assert {:ok, cmd, _} = Commands.build(operation(env, grant, "secrets_write"), env)
    assert cmd.payload.files["github-token"] == "scoped-personal"
  end

  # A personal connection is its owner asking from somewhere else. A build
  # it asks for is the build the owner would get from the browser: with
  # the owner's registry credential for the repo's private features, and
  # from the box's prebuild. Only a service is held to what it was approved.
  describe "a build on a personal connection" do
    setup ctx do
      save(ctx.repo.owner, registry_username: "reader", registry_token: "registry-credential")

      Repo.insert!(%Foreman.Prebuilds.Prebuild{
        repo_id: ctx.repo.id,
        box_id: ctx.box.id,
        branch: "main",
        config_path: ".devcontainer/devcontainer.json",
        status: "ready",
        repos: [ctx.repo.name, ctx.extra.name]
      })

      github()
      {grant, env} = personal(ctx, ctx.admin)
      env = save(env, created_once: false)

      stub(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
        {:ok, %{token: "scoped-personal"}}
      end)

      %{grant: grant, env: env}
    end

    # What GitHub says the owner's token reads, by the ids Foreman knows them by.
    # The build's own token is the one scoped for it; anything else is the
    # owner's sign-in, which is what says they may have the environment at all.
    defp readable(ctx, repos, sign_in \\ nil) do
      ids = fn repos -> Map.new(repos, &{&1.full_name, &1.github_id}) end
      {scoped, sign_in} = {ids.(repos), ids.(sign_in || repos)}

      stub(ClientMock, :get_repo, fn token, name ->
        case if(token == "scoped-personal", do: scoped, else: sign_in) do
          %{^name => id} -> {:ok, %{"id" => id, "full_name" => name}}
          _ -> {:error, :not_found}
        end
      end)

      ctx
    end

    @credential [%{host: "ghcr.io", username: "reader", token: "registry-credential"}]

    test "carries the owner's registry credential, on a create and a start", ctx do
      readable(ctx, [ctx.repo, ctx.extra])

      for action <- ~w(create start) do
        assert {:ok, cmd, _} = Commands.build(operation(ctx.env, ctx.grant, action), ctx.env)
        assert cmd.payload.registry_auth == @credential, action
      end
    end

    # The connection the environment was last started on stays what it runs
    # on. A rebuild its owner then asks for in the browser has to work.
    test "and so does a rebuild from the browser of an environment started on one", ctx do
      readable(ctx, [ctx.repo, ctx.extra])
      env = save(ctx.env, api_grant_id: nil, workload_grant_id: ctx.grant.id, created_once: true)
      rebuild = %{operation(env, ctx.grant, "rebuild") | api_grant_id: nil}

      assert {:ok, %{type: "env.rebuild"} = cmd, _} = Commands.build(rebuild, env)
      assert cmd.payload.registry_auth == @credential
    end

    test "starts from the box's prebuild", ctx do
      readable(ctx, [ctx.repo, ctx.extra])

      assert {:ok, cmd, _} = Commands.build(operation(ctx.env, ctx.grant, "create"), ctx.env)
      assert is_binary(cmd.payload.prebuild_id)
    end

    test "gets neither when its owner can't read everything they were made with", ctx do
      # The repo, but not the second one the prebuild holds.
      readable(ctx, [ctx.repo])
      assert {:ok, cmd, _} = Commands.build(operation(ctx.env, ctx.grant, "create"), ctx.env)
      assert cmd.payload.registry_auth == @credential
      refute Map.has_key?(cmd.payload, :prebuild_id)

      # Not even the repo: there's no build to give anything to.
      readable(ctx, [])
      assert {:error, _} = Commands.build(operation(ctx.env, ctx.grant, "create"), ctx.env)
    end

    # The owner may have the environment, but the token its build clones
    # with reads nothing: that token is the one the check is about.
    test "gets neither when the build's own token can't read the repo", ctx do
      readable(ctx, [], [ctx.repo, ctx.extra])

      assert {:ok, cmd, _} = Commands.build(operation(ctx.env, ctx.grant, "create"), ctx.env)
      refute Map.has_key?(cmd.payload, :registry_auth)
      refute Map.has_key?(cmd.payload, :prebuild_id)
    end

    # The credential is in the prepared command, so one an admin has since
    # replaced or removed mustn't still be sent.
    test "isn't sent with a registry credential that changed after it was prepared", ctx do
      readable(ctx, [ctx.repo, ctx.extra])
      op = operation(ctx.env, ctx.grant, "create")

      for change <- [[registry_token: "rotated"], [registry_username: nil, registry_token: nil]] do
        assert {:ok, cmd, _, proof} = Commands.prepare(op, ctx.env)
        assert [%{token: _}] = cmd.payload.registry_auth
        save(Repo.reload!(ctx.repo.owner), change)

        assert :retry =
                 Environments.WorkloadAccess.deliver(op, ctx.env, proof, fn _ ->
                   flunk("sent a stale registry credential")
                 end)
      end
    end
  end

  test "changed repo, box, or action scope blocks already accepted API work", ctx do
    {grant, _, env} = service(ctx)

    for attrs <- [[box_ids: []], [repo_ids: []], [scopes: ["environments:create"]]] do
      save(grant, attrs)
      assert {:error, _} = Commands.build(operation(env, grant, "start"), env)
      save(Repo.reload!(grant), Map.take(grant, [:box_ids, :repo_ids, :scopes]))
    end
  end

  test "a queued first launch cannot create from a repository removed from the launch catalog",
       ctx do
    {grant, _, env} = service(ctx)
    env = save(env, created_once: false)
    save(ctx.repo, archived: true)

    assert {:error, :unauthorized} = Commands.build(operation(env, grant, "create"), env)
    assert {:ok, _, _} = Commands.build(operation(env, grant, "stop"), env)
  end

  test "a running service workspace renews its archived primary without archived secondaries",
       ctx do
    {grant, _, env} = service(ctx)
    github()
    save(ctx.repo, archived: true)
    save(ctx.extra, archived: true)

    expect(ClientMock, :repo_read_token, fn _, installation, repos ->
      assert installation == ctx.repo.owner.installation_id
      assert repos == {:ids, [ctx.repo.github_id]}
      {:ok, "archived-primary-read"}
    end)

    assert {:ok, cmd, _} = Commands.build(operation(env, grant, "secrets_write"), env)
    assert cmd.payload.files["github-token"] == "archived-primary-read"
  end

  test "a deferred first boot uses the start grant and rechecks launch eligibility", ctx do
    {original, env} = personal(ctx, ctx.admin)
    env = save(env, created_once: false, initial_create_deferred: true)
    OAuth.revoke_grant(original.id)

    grant =
      Repo.insert!(%Grant{
        user_id: ctx.admin.id,
        client_id: "foreman-cli",
        scopes: ["environments:start"]
      })

    start = %{operation(env, grant, "start") | command: "env.create"}

    assert {:ok, %Command{type: "env.create"}, _} = Commands.build(start, env)
    save(ctx.repo, archived: true)
    assert {:error, :unauthorized} = Commands.build(start, env)
  end

  test "a service workload cannot clone a replacement GitHub repository through an old secondary grant",
       ctx do
    github()
    {grant, _, env} = service(ctx)
    save(ctx.extra, github_id: 999_999, github_identity_bound_at: DateTime.utc_now())

    expect(ClientMock, :repo_read_token, fn _, _, ids ->
      assert ids == {:ids, [ctx.repo.github_id]}
      {:ok, "primary-only"}
    end)

    assert {:ok, cmd, _} = Commands.build(operation(env, grant, "secrets_write"), env)
    assert cmd.payload.files["github-token"] == "primary-only"
  end

  test "a grant revoked between issuance and dispatch cannot deliver the token", ctx do
    {grant, _user, env} = service(ctx)
    github()

    expect(ClientMock, :repo_read_token, fn _, _, _ ->
      OAuth.revoke_grant(grant.id)
      {:ok, "already-issued"}
    end)

    assert {:error, _} = Commands.build(operation(env, grant, "secrets_write"), env)
  end

  test "the credential issuer discards a provider response after grant revocation", ctx do
    {grant, _, _env} = service(ctx)
    {:ok, principal} = OAuth.authorize_grant(grant.id)
    github()

    expect(ClientMock, :repo_read_token, fn _, _, _ ->
      OAuth.revoke_grant(grant.id)
      {:ok, "issued-during-revocation"}
    end)

    assert {:error, :unauthorized} =
             Foreman.GitHub.workload_token(principal, ctx.repo, [ctx.repo.github_id])
  end

  test "a service disabled during tailnet enrollment receives and retains no enrollment key",
       ctx do
    {grant, _, env} = service(ctx)
    config(:tailscale, %{client_id: "fixture", client_secret: "fixture"})

    expect(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ ->
      {:ok, :disabled} = ServiceAccounts.disable(Scope.for_user(ctx.admin), grant.client_id)
      {:ok, %{key: "tskey-auth-undelivered", id: "fixture"}}
    end)

    assert {:error, :unauthorized} = Commands.build(operation(env, grant, "create"), env)
    assert is_nil(Repo.reload!(env).ts_authkey)
  end

  test "disabled installation rejects reconciliation and refresh and preserves system expiry",
       ctx do
    {grant, _, env} = service(ctx)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    config(:tailscale, %{client_id: "fixture", client_secret: "fixture"})
    assert {:ok, :disabled} = ServiceAccounts.disable(Scope.for_user(ctx.admin), grant.client_id)
    assert Enum.any?(Accounts.SSHRemovals.outstanding(), &(&1.name == "Build integration"))
    Environments.push_secrets(user_id: env.user_id)
    Environments.reconcile_inventory(ctx.box.id, [])
    refute_receive {:dispatch, _}
    refute Operations.active?(env.id)
    env = save(env, expiry_consumed_at: nil, expiry_action: "stop", expiry_at: DateTime.utc_now())
    expiry = %{operation(env, grant, "stop") | trigger: "expiry", user_id: nil, api_grant_id: nil}
    op = Repo.insert!(expiry)
    Server.kick(env.id)
    assert_receive {:dispatch, %Command{op_id: id, type: "env.stop"}}
    assert id == op.id
  end

  test "a revoked submitted start never produces a reconnect file write on an otherwise eligible workspace",
       ctx do
    {grant, env} = personal(ctx, ctx.admin)

    alternate =
      Repo.insert!(%Grant{
        user_id: ctx.admin.id,
        client_id: "foreman-cli",
        scopes: ["environments:start"]
      })

    op = operation(env, alternate, "start") |> Map.put(:status, "dispatched") |> Repo.insert!()
    OAuth.revoke_grant(alternate.id)
    assert {:ok, _} = OAuth.authorize_grant(grant.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    Server.resend(env.id, op.id)
    refute_receive {:dispatch, _}
    assert Repo.aggregate(Operation, :count) == 1
    assert Repo.reload!(op).status == "failed"
  end

  test "an authorization outage leaves the command queued and later dispatch succeeds", ctx do
    {grant, env} = personal(ctx, ctx.admin)
    github()
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    stub(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
    op = operation(env, grant, "stop") |> Repo.insert!()
    Server.kick(env.id)
    refute_receive {:dispatch, _}
    assert Repo.reload!(op).status == "queued"

    stub(ClientMock, :get_repo, fn _, name ->
      {:ok, %{"id" => if(name == ctx.repo.full_name, do: 101, else: 102), "full_name" => name}}
    end)

    Server.kick(env.id)
    assert_receive {:dispatch, %Command{type: "env.stop"}}
  end

  test "reconciliation cannot resurrect an API start after its own grant was revoked", ctx do
    # A browser-created environment has no origin grant. Its desired state was
    # set by a different client whose permissions have since been withdrawn.
    env =
      environment_fixture(
        user: ctx.admin,
        repo: ctx.repo,
        box: ctx.box,
        desired_state: "stopped",
        observed_state: "stopped"
      )

    grant =
      Repo.insert!(%Grant{
        user_id: ctx.admin.id,
        client_id: "foreman-cli",
        scopes: ["environments:start"]
      })

    {:ok, start} =
      Environments.queue_action(Scope.for_user(ctx.admin), env, :start, %{},
        api_grant_id: grant.id
      )

    for op <- Operations.list_for_environment(env.id), do: Operations.mark(op, "succeeded")
    assert Repo.reload!(start).status == "succeeded"
    OAuth.revoke_grant(grant.id)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)

    Environments.reconcile_inventory(ctx.box.id, [
      %{env_id: env.id, state: "stopped", slug: env.slug}
    ])

    refute_receive {:dispatch, _}
    assert Repo.reload!(env).observed_state == "stopped"
  end

  test "repeated reconnect authorization outages do not pile up secret writes", ctx do
    {grant, env} = personal(ctx, ctx.admin)
    github()
    op = operation(env, grant, "start") |> Map.put(:status, "dispatched") |> Repo.insert!()
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    stub(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
    for _ <- 1..3, do: Server.resend(env.id, op.id)
    assert Repo.aggregate(Operation, :count) == 1
    assert Repo.reload!(op).status == "dispatched"
  end

  test "installation credentials renew before the one-hour GitHub installation token expires",
       ctx do
    {_, _, env} = service(ctx)
    github()
    save(env, token_pushed_at: DateTime.add(DateTime.utc_now(), -32, :minute))
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    expect(ClientMock, :repo_read_token, fn _, _, _ -> {:ok, "new-installation-token"} end)
    assert :ok = Foreman.Jobs.RefreshTokens.perform(%{})
    assert_receive {:dispatch, %Command{type: "env.secrets.write"} = cmd}
    assert cmd.payload.files["github-token"] == "new-installation-token"
  end

  test "a GitHub refresh cannot restore credentials after concurrent offboarding", ctx do
    user = user_fixture(access_token_expires_at: DateTime.add(DateTime.utc_now(), -10))
    github()

    expect(ClientMock, :refresh_user_token, fn _, _ ->
      :ok = Accounts.revoke_access(user, "confirmed loss")
      {:ok, %{access_token: "must-not-return", refresh_token: "rotated", expires_in: 28_800}}
    end)

    assert {:error, :login_expired} = Foreman.GitHub.user_token(user)
    assert is_nil(Accounts.get_user!(user.id).access_token)
    assert is_nil(Accounts.get_user!(user.id).refresh_token)
    assert {:ok, _} = Accounts.set_disabled(Scope.for_user(ctx.admin), user, true)
    assert {:error, :login_expired} = Foreman.GitHub.user_token(user)
  end

  test "confirmed destruction cleans a recorded service node with only its unique approved tag",
       ctx do
    {grant, _, env} = service(ctx)
    save(env, tailscale_device_id: "node1", destroyed_at: DateTime.utc_now())

    config(:tailscale, %{
      client_id: "fixture",
      client_secret: "fixture",
      deployment_tag: "tag:deployment"
    })

    device = %{
      "id" => "1",
      "nodeId" => "node1",
      "hostname" => env.slug,
      "tags" => grant.network_policy["tailscale_tags"]
    }

    other = %{device | "id" => "2", "tags" => ["tag:ci"]}
    expect(Foreman.Tailscale.ClientMock, :list_devices, fn _ -> {:ok, [device, other]} end)
    expect(Foreman.Tailscale.ClientMock, :delete_device, fn _, "1" -> :ok end)
    assert :ok = Foreman.Tailscale.delete_device(env.slug, "node1")
  end

  test "a service replacement cleans the formerly recorded node with its original identity tag",
       ctx do
    {grant, _, env} = service(ctx)
    save(env, tailscale_device_id: "new-node")
    config(:tailscale, %{client_id: "fixture", client_secret: "fixture"})

    old = %{
      "id" => "1",
      "nodeId" => "old-node",
      "hostname" => env.slug,
      "tags" => grant.network_policy["tailscale_tags"]
    }

    new = %{old | "id" => "2", "nodeId" => "new-node"} |> Map.put("name", env.slug)

    expect(Foreman.Tailscale.ClientMock, :list_devices, fn _ -> {:ok, [old, new]} end)
    expect(Foreman.Tailscale.ClientMock, :delete_device, fn _, "1" -> :ok end)
    assert :ok = Foreman.Tailscale.delete_device(env.slug, "old-node", "new-node")
  end

  test "new credentials never preserve a legacy broad token on a transient API mint failure",
       ctx do
    {grant, _, env} = service(ctx)
    github()
    expect(ClientMock, :repo_read_token, fn _, _, _ -> {:error, :timeout} end)
    assert {:ok, cmd, _} = Commands.build(operation(env, grant, "secrets_write"), env)
    refute Map.has_key?(cmd.payload, :keep)
  end

  test "a new personal connection can shut down without reviving the revoked workload grant",
       ctx do
    {old, env} = personal(ctx, ctx.admin)
    OAuth.revoke_grant(old.id)

    fresh =
      Repo.insert!(%Grant{
        user_id: ctx.admin.id,
        client_id: "foreman-cli",
        scopes: ~w(environments:stop environments:destroy)
      })

    for action <- ~w(stop destroy) do
      assert {:ok, cmd, _} = Commands.build(operation(env, fresh, action), env)
      assert cmd.type == "env." <> action
    end

    refute Environments.WorkloadAccess.automatic_active?(env, "secrets_write")
  end

  test "authorized start on a new personal connection binds refresh while preserving creation attribution",
       ctx do
    {old, env} = personal(ctx, ctx.admin)
    OAuth.revoke_grant(old.id)

    fresh =
      Repo.insert!(%Grant{
        user_id: ctx.admin.id,
        client_id: "foreman-cli",
        scopes: ~w(environments:start)
      })

    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    op = operation(env, fresh, "start") |> Repo.insert!()
    Server.kick(env.id)
    assert_receive {:dispatch, %Command{type: "env.start"}}
    assert Repo.reload!(env).api_grant_id == old.id
    assert Repo.reload!(env).workload_grant_id == fresh.id
    Operations.mark(op, "succeeded")
    assert :ok = Environments.push_secrets(user_id: ctx.admin.id)
    assert_receive {:dispatch, %Command{type: "env.secrets.write"}}
    OAuth.revoke_grant(fresh.id)
    refute Environments.WorkloadAccess.automatic_active?(Repo.reload!(env), "secrets_write")
  end

  test "a human disabled during remote scoping receives no token or agent command", ctx do
    scope = Scope.for_user(ctx.admin)
    member = user_fixture()
    box = box_fixture(owner_user_id: member.id)
    env = environment_fixture(user: member, repo: save(ctx.repo, token_mode: "scoped"), box: box)
    github()
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)

    expect(ClientMock, :scope_user_token, fn _, _, _, _, _ ->
      assert {:ok, _} = Accounts.set_disabled(scope, member, true)
      {:ok, %{token: "scoped-before-disable"}}
    end)

    Environments.push_secrets(user_id: env.user_id)
    refute_receive {:dispatch, _}
    assert Repo.reload!(env).observed_state == "running"
  end

  test "a credential prepared before service disable fails the final local delivery check", ctx do
    {grant, _, env} = service(ctx)
    github()
    expect(ClientMock, :repo_read_token, fn _, _, _ -> {:ok, "prepared"} end)
    op = operation(env, grant, "secrets_write")
    assert {:ok, _cmd, _extra, policy} = Commands.prepare(op, env)
    {:ok, :disabled} = ServiceAccounts.disable(Scope.for_user(ctx.admin), grant.client_id)

    assert {:error, :unauthorized} =
             Environments.WorkloadAccess.deliver(op, env, policy, fn _ ->
               flunk("sent prepared credentials after disable")
             end)
  end

  defp service(ctx, secret_ids \\ []) do
    {:ok, %{grant: grant}} =
      ServiceAccounts.register(Scope.for_user(ctx.admin), "service", %{
        "name" => "Build integration",
        "repo_ids" => [ctx.repo.id, ctx.extra.id],
        "box_ids" => [ctx.box.id],
        "scopes" => ~w(environments:create environments:start environments:stop),
        "secret_ids" => secret_ids,
        "tailscale_tags" => ["tag:ci"]
      })

    user = Accounts.get_user!(grant.user_id)

    {grant, user,
     environment_fixture(user: user, repo: ctx.repo, box: ctx.box) |> save(api_grant_id: grant.id)}
  end

  test "delivery rechecks the verified primary and secondary without network calls", ctx do
    {grant, env} = personal(ctx, ctx.admin)
    github()
    local_only = :atomics.new(1, [])

    stub(ClientMock, :get_repo, fn _, name ->
      assert :atomics.get(local_only, 1) == 0
      repo = Enum.find([ctx.repo, ctx.extra, ctx.hidden], &(&1.full_name == name))
      {:ok, %{"id" => repo.github_id, "full_name" => name}}
    end)

    stub(ClientMock, :scope_user_token, fn _, _, _, _, _ -> {:ok, %{token: "scoped"}} end)

    for {target, action} <- [{ctx.extra, "secrets_write"}, {ctx.repo, "stop"}] do
      op = operation(env, grant, action)
      assert {:ok, _, _, proof} = Commands.prepare(op, env)
      :atomics.put(local_only, 1, 1)
      assert :sent = Environments.WorkloadAccess.deliver(op, env, proof, fn _ -> :sent end)
      save(target, full_name: target.full_name <> "-renamed")

      assert Environments.WorkloadAccess.deliver(op, env, proof, fn _ -> :sent end) in [
               :retry,
               {:error, :unauthorized}
             ]

      save(Repo.reload!(target), full_name: target.full_name)
      :atomics.put(local_only, 1, 0)
    end
  end

  test "permission or enrollment changes invalidate a prepared personal command", ctx do
    {grant, env} = personal(ctx, ctx.admin)
    github()
    config(:tailscale, %{client_id: "fixture", client_secret: "fixture"})

    stub(ClientMock, :get_repo, fn _, name ->
      repo = Enum.find([ctx.repo, ctx.extra, ctx.hidden], &(&1.full_name == name))
      {:ok, %{"id" => repo.github_id, "full_name" => name}}
    end)

    stub(ClientMock, :scope_user_token, fn _, _, _, _, _ -> {:ok, %{token: "scoped"}} end)
    stub(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ -> {:ok, %{key: "fixture"}} end)
    op = operation(env, grant, "create")

    for change <- [[token_permissions: %{"contents" => "read"}], [tailscale_tags: []]] do
      assert {:ok, _, _, proof} = Commands.prepare(op, env)
      save(Repo.reload!(ctx.repo), change)
      assert :retry = Environments.WorkloadAccess.deliver(op, env, proof, fn _ -> :sent end)
    end
  end

  test "rotation and deletion supersede service file writes prepared with the old value", ctx do
    secret = secret_fixture("repo", ctx.repo, "APPROVED", "first")
    {grant, _, env} = service(ctx, [secret.id])
    op = operation(env, grant, "secrets_write")
    assert {:ok, _, _, first} = Commands.prepare(op, env)
    rotated = save(Repo.reload!(secret), value: "second")
    assert :retry = Environments.WorkloadAccess.deliver(op, env, first, fn _ -> :sent end)
    assert {:ok, cmd, _, second} = Commands.prepare(op, env)
    assert cmd.payload.files["secrets.env"] =~ "second"
    Repo.delete!(rotated)
    assert :retry = Environments.WorkloadAccess.deliver(op, env, second, fn _ -> :sent end)
  end

  test "an administrator or due expiry can stop ahead of a retrying personal file write", ctx do
    github()
    stub(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)

    for trigger <- [:admin, :expiry] do
      {grant, env} = personal(ctx, ctx.admin)
      write = operation(env, grant, "secrets_write") |> Repo.insert!()
      Server.kick(env.id)
      assert Repo.reload!(write).status == "queued"

      if trigger == :expiry do
        save(Repo.reload!(env), expiry_at: DateTime.utc_now(), expiry_action: "stop")
        Server.kick(env.id)
      else
        assert {:ok, _} = Environments.stop(Scope.for_user(ctx.admin), env)
      end

      assert_receive {:dispatch, %Command{type: "env.stop", op_id: id}}
      assert Repo.reload!(write).status == "cancelled"
      Operations.mark(Operations.get!(id), "succeeded")
    end
  end

  test "a service without repository contents permission receives no installation token", ctx do
    {grant, _, env} = service(ctx)
    save(ctx.repo, token_permissions: %{"contents" => "none"})
    github()
    stub(ClientMock, :repo_read_token, fn _, _, _ -> {:ok, "inappropriate-token"} end)

    assert {:ok, cmd, extra} =
             Commands.build(operation(env, grant, "secrets_write"), Repo.reload!(env))

    refute Map.has_key?(cmd.payload.files, "github-token")
    refute extra["token_retry"]
  end

  test "a browser-scoped credential is discarded when the source sign-in changes", ctx do
    env =
      environment_fixture(
        user: ctx.admin,
        repo: save(ctx.repo, token_mode: "scoped"),
        box: ctx.box
      )

    op = %Operation{
      id: Ecto.UUID.generate(),
      action: "secrets_write",
      command: "env.secrets.write",
      user_id: ctx.admin.id,
      environment_id: env.id,
      box_id: env.box_id,
      args: %{}
    }

    github()
    expect(ClientMock, :scope_user_token, fn _, _, _, _, _ -> {:ok, %{token: "derived"}} end)
    assert {:ok, cmd, _, proof} = Commands.prepare(op, env)
    assert cmd.payload.files["github-token"] == "derived"
    save(ctx.admin, access_token: "replacement")
    assert :retry = Environments.WorkloadAccess.deliver(op, env, proof, fn _ -> :sent end)
  end

  test "a reconnect preserves a guest's running file write but a lost write cannot block shutdown",
       ctx do
    {grant, env} = personal(ctx, ctx.admin)

    write =
      operation(env, grant, "secrets_write") |> Map.put(:status, "running") |> Repo.insert!()

    github()
    stub(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, ctx.box.id}, nil)
    assert {:ok, stop} = Environments.stop(Scope.for_user(ctx.admin), env)

    :ok = Foreman.Agents.restart_clocks(ctx.box.id, [write.id])
    :ok = Foreman.Agents.agent_connected(ctx.box)
    assert Repo.reload!(write).status == "running"
    assert Repo.reload!(stop).status == "queued"
    refute_received {:dispatch, %Command{type: "env.stop"}}

    :ok = Foreman.Agents.restart_clocks(ctx.box.id, [])
    :ok = Foreman.Agents.agent_connected(ctx.box)
    assert_receive {:dispatch, %Command{type: "env.stop", op_id: id}}
    assert id == stop.id
    assert Repo.reload!(write).status == "cancelled"
  end

  defp personal(ctx, user) do
    grant =
      Repo.insert!(%Grant{
        user_id: user.id,
        client_id: "foreman-cli",
        scopes: ~w(environments:create environments:start environments:stop)
      })

    {grant,
     environment_fixture(user: user, repo: ctx.repo, box: ctx.box) |> save(api_grant_id: grant.id)}
  end

  defp operation(env, grant, action),
    do: %Operation{
      id: Ecto.UUID.generate(),
      user_id: grant.user_id,
      api_grant_id: grant.id,
      action: action,
      command: "env." <> action,
      environment_id: env.id,
      box_id: env.box_id,
      args: %{}
    }

  defp save(row, attrs), do: row |> change(attrs) |> Repo.update!()

  defp github,
    do:
      config(:github_app, %{
        app_id: "1",
        client_id: "fixture",
        client_secret: "s",
        private_key: "k"
      })

  defp config(key, value) do
    old = Application.fetch_env(:foreman, key)
    Application.put_env(:foreman, key, value)

    on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:foreman, key, v)
        :error -> Application.delete_env(:foreman, key)
      end
    end)
  end
end
