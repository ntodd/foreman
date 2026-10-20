defmodule Foreman.EnvironmentsTest do
  use Foreman.DataCase
  use Oban.Testing, repo: Foreman.Repo

  import Mox

  alias Foreman.{Agents, Boxes, Environments, Operations, Scope, Secrets}
  alias Foreman.Environments.Environment
  alias Foreman.Jobs.CleanupTailnet
  alias ForemanProtocol.{Command, Event}

  setup :verify_on_exit!

  setup do
    user = user_fixture(git_name: "Mona", git_email: "mona@example.com")
    repo = repo_fixture(name: "storefront")
    box = box_fixture(owner_user_id: user.id)
    %{user: user, repo: repo, box: box, scope: Scope.for_user(user)}
  end

  # Stands in for the agent's channel process.
  defp connect_agent(box) do
    {:ok, _} = Registry.register(Foreman.Registry, {:agent, box.id}, nil)
    :ok
  end

  defp event!(type, payload) do
    {:ok, event} = Event.new(type, payload)
    event
  end

  defp succeed(box, cmd, result \\ %{}) do
    :ok =
      Agents.handle_event(
        box.id,
        event!("op.result", %{op_id: cmd.op_id, status: "ok", result: result})
      )
  end

  defp fail(box, cmd, error) do
    :ok =
      Agents.handle_event(
        box.id,
        event!("op.result", %{op_id: cmd.op_id, status: "error", error: error})
      )
  end

  @up_result %{
    "container_id" => "abc",
    "remote_user" => "vscode",
    "remote_workspace_folder" => "/workspaces/storefront",
    "services" => ["app", "db"],
    "devcontainer_service" => "app",
    "warnings" => ["service 'app' runs privileged"],
    "host_requirements" => %{"cpus" => 4}
  }

  describe "create" do
    test "names it, queues it and sends env.create with everything the agent needs", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      connect_agent(box)

      {:ok, _} =
        Secrets.put_secret(scope, "user", scope.user, %{"name" => "API_KEY", "value" => "k1"})

      assert {:ok, %Environment{slug: "storefront-1"} = env} =
               Environments.create_environment(scope, %{
                 "repo_id" => repo.id,
                 "box_id" => box.id,
                 "branch" => "feature/x"
               })

      assert_receive {:dispatch, %Command{type: "env.create"} = cmd}
      p = cmd.payload
      assert p.env_id == env.id
      assert p.slug == "storefront-1"
      assert p.repo == repo.full_name
      assert p.clone_url == "https://github.com/#{repo.full_name}.git"
      assert p.branch == "feature/x"
      assert p.compose_env == %{"API_KEY" => "k1"}
      assert p.files["secrets.env"] =~ "export API_KEY='k1'"
      assert p.files["gitconfig"] =~ ~s(email = "mona@example.com")
      refute Map.has_key?(p.files, "github-token")
      assert p.tailscale == %{enabled: false, tags: []}

      assert Repo.reload!(env).observed_state == "creating"

      succeed(box, cmd, @up_result)
      env = Repo.reload!(env)
      assert env.observed_state == "running"
      assert env.created_once
      assert env.remote_user == "vscode"
      assert env.services == ["app", "db"]
      assert env.warnings == ["service 'app' runs privileged"]
      assert Map.keys(env.applied_secret_hashes) == ["API_KEY"]
    end

    test "numbers copies and reuses numbers freed by destroyed ones", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      {:ok, e1} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      {:ok, e2} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert {e1.slug, e2.slug} == {"storefront-1", "storefront-2"}

      Repo.update!(Ecto.Changeset.change(e1, destroyed_at: DateTime.utc_now()))

      {:ok, e3} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert e3.slug == "storefront-1"
    end

    test "team deployments put the login in the slug", %{scope: scope, repo: repo, box: box} do
      Application.put_env(:foreman, :slug_style, :team)
      on_exit(fn -> Application.put_env(:foreman, :slug_style, :personal) end)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert env.slug == "storefront-#{scope.user.login}-1"
    end

    test "refuses boxes the user can't use and repos without a devcontainer", %{
      scope: scope,
      repo: repo
    } do
      other_box = box_fixture(owner_user_id: user_fixture().id)

      assert {:error, "you can't use that box"} =
               Environments.create_environment(scope, %{
                 "repo_id" => repo.id,
                 "box_id" => other_box.id
               })

      bare = repo_fixture(devcontainer_path: nil)
      box = box_fixture(owner_user_id: scope.user.id)

      assert {:error, "that repo has no devcontainer"} =
               Environments.create_environment(scope, %{"repo_id" => bare.id, "box_id" => box.id})
    end

    test "applies the box's capacity policy", %{scope: scope} do
      big = repo_fixture(host_requirements: %{"cpus" => 32, "memory" => "8gb"})
      warn_box = box_fixture(owner_user_id: scope.user.id, capacity_policy: "warn")
      refuse_box = box_fixture(owner_user_id: scope.user.id, capacity_policy: "refuse")
      allow_box = box_fixture(owner_user_id: scope.user.id)

      assert {:confirm, message} =
               Environments.create_environment(scope, %{
                 "repo_id" => big.id,
                 "box_id" => warn_box.id
               })

      assert message =~ "32 CPUs"

      assert {:ok, _} =
               Environments.create_environment(scope, %{
                 "repo_id" => big.id,
                 "box_id" => warn_box.id,
                 "confirm" => "true"
               })

      assert {:error, _} =
               Environments.create_environment(scope, %{
                 "repo_id" => big.id,
                 "box_id" => refuse_box.id
               })

      assert {:ok, _} =
               Environments.create_environment(scope, %{
                 "repo_id" => big.id,
                 "box_id" => allow_box.id
               })
    end

    test "a failed create leaves the environment in error with the agent's message", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      fail(box, cmd, "devcontainer up failed: build failed")

      env = Repo.reload!(env)
      assert env.observed_state == "error"
      assert env.status_message =~ "build failed"
    end
  end

  describe "dispatch" do
    test "waits for the box to connect, then sends what's queued", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      refute_received {:dispatch, _}
      assert [%{status: "queued"}] = Operations.list_for_environment(env.id)

      connect_agent(box)
      Agents.agent_connected(box)
      assert_receive {:dispatch, %Command{type: "env.create"}}
    end

    test "sends one operation at a time per environment", %{scope: scope, repo: repo, box: box} do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, create}

      {:ok, _} = Environments.stop(scope, env)
      refute_received {:dispatch, _}

      succeed(box, create, @up_result)
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}

      succeed(box, stop)
      assert Repo.reload!(env).observed_state == "stopped"
      assert Repo.reload!(env).desired_state == "stopped"
    end

    test "resends in-flight operations with the same op_id after a reconnect", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      connect_agent(box)

      {:ok, _env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, first}

      Agents.agent_connected(box)
      assert_receive {:dispatch, again}
      assert again.op_id == first.op_id
    end

    test "start sends fresh secrets first", %{scope: scope, box: box, user: user, repo: repo} do
      env =
        environment_fixture(
          user: user,
          repo: repo,
          box: box,
          observed_state: "stopped",
          desired_state: "stopped"
        )

      connect_agent(box)

      {:ok, _} = Environments.start(scope, env)
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
      succeed(box, write)
      assert_receive {:dispatch, %Command{type: "env.start"}}
    end
  end

  describe "redaction" do
    test "secret values are scrubbed from stored logs and errors, even ones the agent couldn't know",
         %{scope: scope, box: box, user: user, repo: repo} do
      env = environment_fixture(user: user, repo: repo, box: box)
      connect_agent(box)

      {:ok, _} =
        Secrets.put_secret(scope, "environment", env, %{
          "name" => "SIDECAR_TOKEN",
          "value" => "hunter2-very-secret"
        })

      flush_dispatches()

      {:ok, op} = Environments.logs(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.logs", op_id: op_id}}
      assert op_id == op.id

      Operations.subscribe(op_id)

      :ok =
        Agents.handle_event(
          box.id,
          event!("op.log", %{
            op_id: op_id,
            stream: "stdout",
            data: "sidecar token=hunter2-very-secret\n"
          })
        )

      assert_receive {:op_log, ^op_id, "sidecar token=[redacted]\n"}

      :ok =
        Agents.handle_event(
          box.id,
          event!("op.result", %{
            op_id: op_id,
            status: "error",
            error: "died printing hunter2-very-secret"
          })
        )

      op = Operations.get!(op_id)
      refute Operations.log(op) =~ "hunter2"
      refute op.error =~ "hunter2"
    end
  end

  defp flush_dispatches do
    receive do
      {:dispatch, %Command{} = cmd} ->
        if cmd.type == "env.secrets.write", do: succeed_any(cmd)
        flush_dispatches()
    after
      0 -> :ok
    end
  end

  defp succeed_any(cmd) do
    op = Operations.get!(cmd.op_id)
    :ok = Agents.handle_event(op.box_id, event!("op.result", %{op_id: cmd.op_id, status: "ok"}))
  end

  describe "events" do
    test "are refused for another box's operations and environments", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}

      intruder = box_fixture()

      assert {:error, :not_yours} =
               Agents.handle_event(
                 intruder.id,
                 event!("op.result", %{op_id: cmd.op_id, status: "ok"})
               )

      assert {:error, :not_yours} =
               Agents.handle_event(
                 intruder.id,
                 event!("env.state", %{env_id: env.id, state: "stopped"})
               )

      assert Repo.reload!(env).observed_state == "creating"
    end

    test "a repeated result is applied once", %{scope: scope, repo: repo, box: box} do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      succeed(box, cmd, @up_result)
      {:ok, _} = Environments.stop(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.stop"}}

      succeed(box, cmd, @up_result)
      assert Repo.reload!(env).observed_state == "stopping"
    end
  end

  describe "secrets changes" do
    setup %{scope: scope, repo: repo, box: box} do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      succeed(box, cmd, @up_result)
      %{env: env}
    end

    test "push new files now and mark the environment pending restart", %{
      scope: scope,
      env: env,
      box: box
    } do
      {:ok, _} =
        Secrets.put_secret(scope, "environment", Repo.reload!(env), %{
          "name" => "NEON_API_KEY",
          "value" => "n1"
        })

      env = Repo.reload!(env)
      assert env.pending_restart
      assert env.pending_changes == ["NEON_API_KEY"]

      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
      assert write.payload.files["secrets.env"] =~ "NEON_API_KEY='n1'"
      assert write.payload.files["notices"] =~ "secrets changed (NEON_API_KEY)"
      succeed(box, write)

      {:ok, _} = Environments.restart(scope, env, :affected)
      assert_receive {:dispatch, %Command{type: "env.restart"} = restart}
      assert restart.payload.mode == "affected"
      assert restart.payload.changed == ["NEON_API_KEY"]
      assert restart.payload.compose_env == %{"NEON_API_KEY" => "n1"}

      succeed(box, restart, @up_result)
      env = Repo.reload!(env)
      refute env.pending_restart
      assert env.pending_changes == []

      # The files it has still say secrets changed; send them again without.
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = rewrite}
      refute rewrite.payload.files["notices"] =~ "secrets changed"
    end

    test "a stop and start takes the secrets-changed notice back out", %{
      scope: scope,
      env: env,
      box: box
    } do
      {:ok, _} =
        Secrets.put_secret(scope, "environment", Repo.reload!(env), %{
          "name" => "NEON_API_KEY",
          "value" => "n1"
        })

      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
      succeed(box, write)

      {:ok, _} = Environments.stop(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      succeed(box, stop)

      # Start sends the files first, while the old secrets are still the
      # applied ones, so they carry the notice.
      {:ok, _} = Environments.start(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = before_start}
      assert before_start.payload.files["notices"] =~ "secrets changed (NEON_API_KEY)"
      succeed(box, before_start)

      assert_receive {:dispatch, %Command{type: "env.start"} = start}
      succeed(box, start, @up_result)
      refute Repo.reload!(env).pending_restart

      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = rewrite}
      refute rewrite.payload.files["notices"] =~ "secrets changed"
    end

    test "a start with nothing changed doesn't send the files again", %{
      scope: scope,
      env: env,
      box: box
    } do
      {:ok, _} = Environments.stop(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.stop"} = stop}
      succeed(box, stop)

      {:ok, _} = Environments.start(scope, Repo.reload!(env))
      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
      succeed(box, write)
      assert_receive {:dispatch, %Command{type: "env.start"} = start}
      succeed(box, start, @up_result)

      refute_receive {:dispatch, %Command{type: "env.secrets.write"}}
    end

    test "setting a secret back to what's applied clears pending restart", %{
      scope: scope,
      env: env
    } do
      {:ok, _} = Secrets.put_secret(scope, "user", scope.user, %{"name" => "A", "value" => "1"})
      assert Repo.reload!(env).pending_restart
      :ok = Secrets.delete_secret(scope, "user", scope.user, "A")
      refute Repo.reload!(env).pending_restart
    end
  end

  describe "reconcile_inventory/2" do
    setup %{user: user, repo: repo, box: box} do
      connect_agent(box)
      %{env: environment_fixture(user: user, repo: repo, box: box)}
    end

    test "starts a stopped environment that should be running (after a reboot)", %{
      env: env,
      box: box
    } do
      Environments.reconcile_inventory(box.id, [
        %{env_id: env.id, slug: env.slug, state: "stopped", containers: []}
      ])

      assert_receive {:dispatch, %Command{type: "env.secrets.write"} = write}
      succeed(box, write)
      assert_receive {:dispatch, %Command{type: "env.start"}}
    end

    test "recreates one that's gone from the box", %{env: env, box: box} do
      Environments.reconcile_inventory(box.id, [])
      assert_receive {:dispatch, %Command{type: "env.create", payload: %{env_id: id}}}
      assert id == env.id
    end

    test "stops one that should be stopped", %{env: env, box: box} do
      Repo.update!(Ecto.Changeset.change(env, desired_state: "stopped"))

      Environments.reconcile_inventory(box.id, [
        %{env_id: env.id, slug: env.slug, state: "running", containers: []}
      ])

      assert_receive {:dispatch, %Command{type: "env.stop"}}
    end

    test "leaves environments in error alone, so failures don't loop", %{env: env, box: box} do
      Repo.update!(Ecto.Changeset.change(env, observed_state: "error"))

      Environments.reconcile_inventory(box.id, [
        %{env_id: env.id, slug: env.slug, state: "stopped", containers: []}
      ])

      refute_received {:dispatch, _}
    end

    test "records environments the box has that Foreman doesn't know", %{env: env, box: box} do
      stranger = %{
        env_id: Ecto.UUID.generate(),
        slug: "mystery-1",
        state: "running",
        containers: []
      }

      Environments.reconcile_inventory(box.id, [
        %{env_id: env.id, slug: env.slug, state: "running", containers: []},
        stranger
      ])

      assert Environments.orphans(box.id) == ["mystery-1"]
    end
  end

  describe "GitHub tokens" do
    setup do
      Application.put_env(:foreman, :github_app, %{
        app_id: "1",
        client_id: "Iv1.x",
        client_secret: "s",
        private_key: "k"
      })

      on_exit(fn -> Application.delete_env(:foreman, :github_app) end)
    end

    test "environments get a token scoped to their repo and its extra repos", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      repo = Repo.update!(Ecto.Changeset.change(repo, extra_repos: ["storefront-assets"]))
      connect_agent(box)
      test_pid = self()

      expect(Foreman.GitHub.ClientMock, :scope_user_token, fn _app,
                                                              "ghu_" <> _,
                                                              target,
                                                              repos,
                                                              perms ->
        send(test_pid, {:scoped, target, repos, perms})
        {:ok, %{token: "ghs_scoped", expires_at: nil}}
      end)

      {:ok, _} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      assert cmd.payload.files["github-token"] == "ghs_scoped"

      assert_receive {:scoped, target, ["storefront", "storefront-assets"],
                      %{"contents" => "write"}}

      assert target == repo.owner.login
    end

    test "broad repos get the user's own token", %{scope: scope, repo: repo, box: box} do
      repo = Repo.update!(Ecto.Changeset.change(repo, token_mode: "broad"))
      connect_agent(box)

      {:ok, _} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      assert cmd.payload.files["github-token"] == scope.user.access_token
    end

    test "an expired GitHub login keeps the environment going with a notice", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      user =
        Repo.update!(
          Ecto.Changeset.change(scope.user,
            access_token_expires_at: DateTime.add(DateTime.utc_now(), -10)
          )
        )

      expect(Foreman.GitHub.ClientMock, :refresh_user_token, fn _app, _ ->
        {:error, :bad_refresh_token}
      end)

      connect_agent(box)

      {:ok, _} =
        Environments.create_environment(Scope.for_user(user), %{
          "repo_id" => repo.id,
          "box_id" => box.id
        })

      assert_receive {:dispatch, cmd}
      refute Map.has_key?(cmd.payload.files, "github-token")
      assert cmd.payload.files["notices"] =~ "GitHub login expired"
      assert Repo.reload!(user).github_login_expired
    end
  end

  describe "Tailscale" do
    setup do
      Application.put_env(:foreman, :tailscale, %{
        client_id: "c",
        client_secret: "s",
        tailnet: "-",
        tags: []
      })

      on_exit(fn -> Application.delete_env(:foreman, :tailscale) end)
    end

    test "a new environment gets a single-use auth key with its tags, once", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      repo = Repo.update!(Ecto.Changeset.change(repo, tailscale_tags: ["tag:staging-access"]))
      connect_agent(box)

      expect(Foreman.Tailscale.ClientMock, :create_auth_key, fn _creds, %{tags: tags} ->
        assert tags == ["tag:foreman-env", "tag:staging-access"]
        {:ok, %{key: "tskey-auth-x", id: "k1"}}
      end)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      assert cmd.payload.files["ts-authkey"] == "tskey-auth-x"
      assert cmd.payload.tailscale.enabled

      succeed(box, cmd, @up_result)
      assert Repo.reload!(env).ts_authkey == nil
    end

    test "records the node the environment joined as", %{scope: scope, repo: repo, box: box} do
      connect_agent(box)

      stub(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ ->
        {:ok, %{key: "k", id: "1"}}
      end)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      succeed(box, cmd, Map.put(@up_result, "tailscale_node_id", "nAbc123CNTRL"))

      assert Repo.reload!(env).tailscale_device_id == "nAbc123CNTRL"
      refute_enqueued(worker: CleanupTailnet)
    end

    test "ignores a node ID that isn't one", %{scope: scope, repo: repo, box: box} do
      connect_agent(box)

      stub(Foreman.Tailscale.ClientMock, :create_auth_key, fn _, _ ->
        {:ok, %{key: "k", id: "1"}}
      end)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, cmd}
      succeed(box, cmd, Map.put(@up_result, "tailscale_node_id", "n1/../../devices"))

      assert Repo.reload!(env).tailscale_device_id == nil
    end

    test "a destroy removes the recorded device", %{
      scope: scope,
      user: user,
      repo: repo,
      box: box
    } do
      connect_agent(box)
      env = environment_fixture(user: user, repo: repo, box: box, tailscale_device_id: "nAbc")

      {:ok, _} = Environments.destroy(scope, env)
      assert_receive {:dispatch, %Command{type: "env.destroy"} = cmd}
      succeed(box, cmd)

      assert_enqueued(worker: CleanupTailnet, args: %{"slug" => env.slug, "device_id" => "nAbc"})
    end

    test "a destroy on a revoked box removes the recorded device", %{
      scope: scope,
      user: user,
      repo: repo,
      box: box
    } do
      env = environment_fixture(user: user, repo: repo, box: box, tailscale_device_id: "nAbc")
      admin = Scope.for_user(user_fixture(role: "admin"))
      {:ok, _} = Boxes.revoke(admin, Boxes.get_box!(box.id))

      {:ok, _} = Environments.destroy(scope, Repo.reload!(env))

      assert_enqueued(worker: CleanupTailnet, args: %{"slug" => env.slug, "device_id" => "nAbc"})
    end

    test "a new node queues removal of the one it replaced", %{
      scope: scope,
      user: user,
      repo: repo,
      box: box
    } do
      connect_agent(box)
      env = environment_fixture(user: user, repo: repo, box: box, tailscale_device_id: "nOld")

      {:ok, _} = Environments.rebuild(scope, env)
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}
      succeed(box, cmd, Map.put(@up_result, "tailscale_node_id", "nNew"))

      assert Repo.reload!(env).tailscale_device_id == "nNew"

      assert_enqueued(
        worker: CleanupTailnet,
        args: %{"slug" => env.slug, "device_id" => "nOld", "replaced_by" => "nNew"}
      )
    end

    test "the same node queues nothing", %{scope: scope, user: user, repo: repo, box: box} do
      connect_agent(box)
      env = environment_fixture(user: user, repo: repo, box: box, tailscale_device_id: "nSame")

      {:ok, _} = Environments.rebuild(scope, env)
      assert_receive {:dispatch, %Command{type: "env.rebuild"} = cmd}
      succeed(box, cmd, Map.put(@up_result, "tailscale_node_id", "nSame"))

      refute_enqueued(worker: CleanupTailnet)
    end
  end

  describe "cancel_operation" do
    test "kills a running create on the box and leaves the environment ready to retry", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, %Command{type: "env.create"} = create}
      :ok = Agents.handle_event(box.id, event!("op.accepted", %{op_id: create.op_id}))

      assert {:ok, _} = Environments.cancel_operation(scope, env, create.op_id)

      assert_receive {:dispatch, %Command{type: "op.cancel"} = cancel}
      assert cancel.payload.target_op_id == create.op_id
      assert Operations.get!(create.op_id).status == "running"

      # What the agent reports for the killed operation, then for op.cancel.
      fail(box, create, "cancelled")
      succeed(box, cancel)

      assert Operations.get!(create.op_id).status == "cancelled"
      assert Operations.get!(cancel.op_id).status == "succeeded"
      env = Repo.reload!(env)
      assert env.observed_state == "error"
      assert env.status_message == "cancelled"
    end

    test "drops a queued operation without asking the box", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      [op] = Operations.list_for_environment(env.id)
      assert op.status == "queued"

      assert {:ok, %{status: "cancelled"}} = Environments.cancel_operation(scope, env, op.id)
      refute_received {:dispatch, _}
      assert Repo.reload!(env).observed_state == "error"
    end

    test "says so when the box is offline", %{scope: scope, repo: repo, box: box} do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, %Command{type: "env.create"} = create}
      Registry.unregister(Foreman.Registry, {:agent, box.id})

      assert {:error, "The box is offline" <> _} =
               Environments.cancel_operation(scope, env, create.op_id)

      assert Operations.get!(create.op_id).status == "dispatched"
    end

    test "refuses finished operations, other environments' and other people's", %{
      scope: scope,
      repo: repo,
      box: box
    } do
      connect_agent(box)

      {:ok, env} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert_receive {:dispatch, %Command{type: "env.create"} = create}

      {:ok, other} =
        Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box.id})

      assert {:error, "That operation isn't" <> _} =
               Environments.cancel_operation(scope, other, create.op_id)

      stranger = Scope.for_user(user_fixture())
      assert {:error, :unauthorized} = Environments.cancel_operation(stranger, env, create.op_id)

      succeed(box, create, @up_result)

      assert {:error, "That operation has already finished."} =
               Environments.cancel_operation(scope, env, create.op_id)
    end
  end
end
