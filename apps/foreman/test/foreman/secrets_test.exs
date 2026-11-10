defmodule Foreman.SecretsTest do
  use Foreman.DataCase

  alias Foreman.{Scope, Secrets}
  alias Foreman.Secrets.Secret

  setup do
    admin = user_fixture(role: "admin")
    user = user_fixture()
    repo = repo_fixture()
    env = environment_fixture(user: user, repo: repo)
    %{admin: admin, user: user, repo: repo, env: env, owner: repo.owner}
  end

  describe "resolve/1" do
    test "later scopes win: owner < repo < user < environment", %{
      admin: admin,
      user: user,
      repo: repo,
      env: env,
      owner: owner
    } do
      a = Scope.for_user(admin)
      u = Scope.for_user(user)

      {:ok, _} = Secrets.put_secret(a, "owner", owner, %{"name" => "A", "value" => "owner"})
      {:ok, _} = Secrets.put_secret(a, "owner", owner, %{"name" => "B", "value" => "owner"})
      {:ok, _} = Secrets.put_secret(a, "repo", repo, %{"name" => "B", "value" => "repo"})
      {:ok, _} = Secrets.put_secret(a, "repo", repo, %{"name" => "C", "value" => "repo"})
      {:ok, _} = Secrets.put_secret(u, "user", user, %{"name" => "C", "value" => "user"})
      {:ok, _} = Secrets.put_secret(u, "user", user, %{"name" => "D", "value" => "user"})
      {:ok, _} = Secrets.put_secret(u, "environment", env, %{"name" => "D", "value" => "env"})

      assert Secrets.resolve(env) == %{"A" => "owner", "B" => "repo", "C" => "user", "D" => "env"}
    end

    test "a user secret limited to selected repos only reaches those repos", %{
      user: user,
      env: env
    } do
      other_repo = repo_fixture()
      u = Scope.for_user(user)

      {:ok, _} =
        Secrets.put_secret(u, "user", user, %{
          "name" => "ONLY_OTHER",
          "value" => "x",
          "repo_ids" => [other_repo.id]
        })

      {:ok, _} =
        Secrets.put_secret(u, "user", user, %{
          "name" => "MINE",
          "value" => "y",
          "repo_ids" => [env.repo_id]
        })

      assert Secrets.resolve(env) == %{"MINE" => "y"}
    end

    test "another user's secrets never leak into an environment", %{env: env} do
      other = user_fixture()

      {:ok, _} =
        Secrets.put_secret(Scope.for_user(other), "user", other, %{
          "name" => "THEIRS",
          "value" => "x"
        })

      assert Secrets.resolve(env) == %{}
    end
  end

  describe "authorization" do
    test "members can't write owner or repo secrets, or another user's", %{
      user: user,
      repo: repo,
      owner: owner
    } do
      u = Scope.for_user(user)

      assert {:error, :unauthorized} =
               Secrets.put_secret(u, "owner", owner, %{"name" => "A", "value" => "x"})

      assert {:error, :unauthorized} =
               Secrets.put_secret(u, "repo", repo, %{"name" => "A", "value" => "x"})

      assert {:error, :unauthorized} =
               Secrets.put_secret(u, "user", user_fixture(), %{"name" => "A", "value" => "x"})

      other_env = environment_fixture()

      assert {:error, :unauthorized} =
               Secrets.put_secret(u, "environment", other_env, %{"name" => "A", "value" => "x"})
    end
  end

  describe "promote_secret/4" do
    test "moves an environment secret to its owner's secrets, for the environment's repo", %{
      user: user,
      repo: repo,
      env: env
    } do
      u = Scope.for_user(user)
      sibling = environment_fixture(user: user, repo: repo)
      elsewhere = environment_fixture(user: user)
      {:ok, _} = Secrets.put_secret(u, "environment", env, %{"name" => "K", "value" => "v"})

      assert {:ok, promoted} = Secrets.promote_secret(u, env, "K", "user")
      assert promoted.scope == "user"
      assert promoted.repo_ids == [repo.id]
      assert promoted.value == nil

      assert {:ok, []} = Secrets.list_secrets(u, "environment", env)
      assert Secrets.resolve(env) == %{"K" => "v"}
      assert Secrets.resolve(sibling) == %{"K" => "v"}
      assert Secrets.resolve(elsewhere) == %{}
    end

    test "moves an environment secret to the repo when its owner is an admin", %{
      admin: admin,
      repo: repo
    } do
      a = Scope.for_user(admin)
      env = environment_fixture(user: admin, repo: repo)
      {:ok, _} = Secrets.put_secret(a, "environment", env, %{"name" => "K", "value" => "v"})

      # As if the environment restarted with K since it was set.
      Repo.update!(
        Ecto.Changeset.change(env,
          applied_secret_hashes: Secrets.hashes(Secrets.resolve(env)),
          pending_restart: false,
          pending_changes: []
        )
      )

      teammate_env = environment_fixture(repo: repo)

      assert {:ok, %{scope: "repo"}} = Secrets.promote_secret(a, env, "K", "repo")
      assert Secrets.resolve(env) == %{"K" => "v"}
      assert Secrets.resolve(teammate_env) == %{"K" => "v"}
      assert Repo.reload!(teammate_env).pending_changes == ["K"]
      refute Repo.reload!(env).pending_restart

      [event] = Foreman.Audit.recent() |> Enum.filter(&(&1.action == "secret.promote"))

      assert event.metadata == %{
               "name" => "K",
               "from" => "environment:" <> env.id,
               "scope" => "repo:" <> repo.id
             }

      refute inspect(event) =~ ~s("v")
    end

    test "only by the environment's owner, and only to a level they can write", %{
      admin: admin,
      user: user,
      repo: repo,
      env: env
    } do
      {:ok, _} =
        Secrets.put_secret(Scope.for_user(user), "environment", env, %{
          "name" => "K",
          "value" => "v"
        })

      assert {:error, :unauthorized} =
               Secrets.promote_secret(Scope.for_user(user), env, "K", "repo")

      # An admin can replace or delete someone's environment secret, but
      # moving it somewhere their own environments get it would show them
      # the value.
      assert {:error, :unauthorized} =
               Secrets.promote_secret(Scope.for_user(admin), env, "K", "repo")

      assert {:error, :unauthorized} =
               Secrets.promote_secret(Scope.for_user(admin), env, "K", "user")

      assert {:error, :unauthorized} =
               Secrets.promote_secret(Scope.for_user(user_fixture()), env, "K", "user")

      assert {:error, :unauthorized} =
               Secrets.promote_secret(Scope.for_user(user), env, "K", "owner")

      assert {:error, :unauthorized} =
               Secrets.promote_secret(Scope.for_user(admin), repo, "K", "repo")

      assert Secrets.resolve(env) == %{"K" => "v"}
      assert Repo.aggregate(Secret, :count) == 1
    end

    test "refuses when the level above already has a secret with that name", %{
      user: user,
      env: env
    } do
      u = Scope.for_user(user)
      other_repo = repo_fixture()

      {:ok, _} =
        Secrets.put_secret(u, "user", user, %{
          "name" => "K",
          "value" => "theirs",
          "repo_ids" => [other_repo.id]
        })

      {:ok, _} = Secrets.put_secret(u, "environment", env, %{"name" => "K", "value" => "v"})

      assert {:error, :exists} = Secrets.promote_secret(u, env, "K", "user")
      assert Secrets.resolve(env) == %{"K" => "v"}
      assert Repo.aggregate(Secret, :count) == 2
    end

    test "refuses when a level in between would override it in this environment", %{
      admin: admin,
      repo: repo
    } do
      a = Scope.for_user(admin)
      env = environment_fixture(user: admin, repo: repo)
      {:ok, _} = Secrets.put_secret(a, "user", admin, %{"name" => "K", "value" => "mine"})
      {:ok, _} = Secrets.put_secret(a, "environment", env, %{"name" => "K", "value" => "v"})

      assert {:error, :overridden} = Secrets.promote_secret(a, env, "K", "repo")
      assert Secrets.resolve(env) == %{"K" => "v"}
      assert Repo.aggregate(Secret, :count) == 2
    end

    test "a missing secret is not found", %{user: user, env: env} do
      assert {:error, :not_found} =
               Secrets.promote_secret(Scope.for_user(user), env, "NOPE", "user")
    end
  end

  describe "storage" do
    test "values are encrypted at rest and never returned", %{user: user} do
      {:ok, secret} =
        Secrets.put_secret(Scope.for_user(user), "user", user, %{
          "name" => "TOKEN",
          "value" => "hunter2"
        })

      assert secret.value == nil

      raw = Repo.one(from s in "secrets", where: s.name == "TOKEN", select: s.value)
      refute raw =~ "hunter2"

      {:ok, [listed]} = Secrets.list_secrets(Scope.for_user(user), "user", user)
      assert listed.name == "TOKEN"
      assert listed.value == nil
    end

    test "putting a name again replaces the value", %{user: user, env: env} do
      u = Scope.for_user(user)
      {:ok, _} = Secrets.put_secret(u, "user", user, %{"name" => "K", "value" => "1"})
      {:ok, _} = Secrets.put_secret(u, "user", user, %{"name" => "K", "value" => "2"})
      assert Repo.aggregate(Secret, :count) == 1
      assert Secrets.resolve(env) == %{"K" => "2"}
    end

    test "rejects reserved and invalid names", %{user: user} do
      u = Scope.for_user(user)

      for name <-
            ["PATH", "LD_PRELOAD", "LD_AUDIT", "GIT_CONFIG_KEY_0", "FOREMAN_X", "1ABC"] ++
              ["A-B", "a b", "DOCKER_HOST"] do
        assert {:error, changeset} =
                 Secrets.put_secret(u, "user", user, %{"name" => name, "value" => "x"})

        assert errors_on(changeset).name != [], "expected #{name} to be rejected"
      end
    end

    test "the audit log records names, not values", %{user: user} do
      {:ok, _} =
        Secrets.put_secret(Scope.for_user(user), "user", user, %{
          "name" => "K",
          "value" => "supersecret"
        })

      [event] = Foreman.Audit.recent() |> Enum.filter(&(&1.action == "secret.create"))
      assert event.metadata["name"] == "K"
      refute inspect(event) =~ "supersecret"
    end
  end

  describe "list_inherited_secrets/3" do
    test "an environment sees the owner, repo and user secrets it gets, by level", %{
      admin: admin,
      user: user,
      repo: repo,
      env: env,
      owner: owner
    } do
      a = Scope.for_user(admin)
      u = Scope.for_user(user)

      {:ok, _} = Secrets.put_secret(a, "owner", owner, %{"name" => "ORG_KEY", "value" => "x"})
      {:ok, _} = Secrets.put_secret(a, "repo", repo, %{"name" => "SHARED", "value" => "x"})
      {:ok, _} = Secrets.put_secret(a, "repo", repo, %{"name" => "DB_URL", "value" => "x"})
      {:ok, _} = Secrets.put_secret(u, "user", user, %{"name" => "SHARED", "value" => "x"})
      {:ok, _} = Secrets.put_secret(u, "environment", env, %{"name" => "OWN", "value" => "x"})

      assert {:ok, inherited} = Secrets.list_inherited_secrets(u, "environment", env)

      assert Enum.map(inherited, &{&1.scope, &1.name}) == [
               {"owner", "ORG_KEY"},
               {"repo", "DB_URL"},
               {"repo", "SHARED"},
               {"user", "SHARED"}
             ]

      assert Enum.all?(inherited, &is_nil(&1.value))
    end

    test "an environment leaves out user secrets limited to other repos and other users' secrets",
         %{user: user, env: env} do
      other_repo = repo_fixture()
      other = user_fixture()
      u = Scope.for_user(user)

      {:ok, _} =
        Secrets.put_secret(u, "user", user, %{
          "name" => "ONLY_OTHER",
          "value" => "x",
          "repo_ids" => [other_repo.id]
        })

      {:ok, _} =
        Secrets.put_secret(u, "user", user, %{
          "name" => "MINE",
          "value" => "y",
          "repo_ids" => [env.repo_id]
        })

      {:ok, _} =
        Secrets.put_secret(Scope.for_user(other), "user", other, %{
          "name" => "THEIRS",
          "value" => "z"
        })

      assert {:ok, [%{scope: "user", name: "MINE"}]} =
               Secrets.list_inherited_secrets(u, "environment", env)
    end

    test "an environment leaves out another owner's and another repo's secrets", %{
      admin: admin,
      user: user,
      env: env
    } do
      a = Scope.for_user(admin)
      other_repo = repo_fixture()

      {:ok, _} =
        Secrets.put_secret(a, "owner", other_repo.owner, %{"name" => "O", "value" => "x"})

      {:ok, _} = Secrets.put_secret(a, "repo", other_repo, %{"name" => "R", "value" => "x"})

      assert {:ok, []} = Secrets.list_inherited_secrets(Scope.for_user(user), "environment", env)
    end

    test "an admin on someone else's environment doesn't see that user's own secret names", %{
      admin: admin,
      user: user,
      repo: repo,
      env: env
    } do
      a = Scope.for_user(admin)
      {:ok, _} = Secrets.put_secret(a, "repo", repo, %{"name" => "DB_URL", "value" => "x"})

      {:ok, _} =
        Secrets.put_secret(Scope.for_user(user), "user", user, %{"name" => "MINE", "value" => "y"})

      assert {:ok, [%{scope: "repo", name: "DB_URL"}]} =
               Secrets.list_inherited_secrets(a, "environment", env)
    end

    test "a repo sees its owner's secrets", %{admin: admin, repo: repo, owner: owner} do
      a = Scope.for_user(admin)
      {:ok, _} = Secrets.put_secret(a, "owner", owner, %{"name" => "ORG_KEY", "value" => "x"})
      {:ok, _} = Secrets.put_secret(a, "repo", repo, %{"name" => "OWN", "value" => "x"})

      assert {:ok, [%{scope: "owner", name: "ORG_KEY", value: nil}]} =
               Secrets.list_inherited_secrets(a, "repo", repo)
    end

    test "an owner has nothing above it", %{admin: admin, owner: owner} do
      a = Scope.for_user(admin)
      {:ok, _} = Secrets.put_secret(a, "owner", owner, %{"name" => "ORG_KEY", "value" => "x"})

      assert {:ok, []} = Secrets.list_inherited_secrets(a, "owner", owner)
    end

    test "follows the level's own authorization", %{user: user, repo: repo, env: env} do
      other = Scope.for_user(user_fixture())

      assert {:error, :unauthorized} = Secrets.list_inherited_secrets(other, "environment", env)

      assert {:error, :unauthorized} =
               Secrets.list_inherited_secrets(Scope.for_user(user), "repo", repo)
    end
  end

  describe "rendering" do
    test "secrets.env quotes values so the shell takes them literally" do
      rendered = Secrets.render_env_file(%{"A" => "it's $HOME `id` \\n", "B" => "line1\nline2"})

      {out, 0} =
        System.cmd("sh", ["-c", rendered <> "\nprintf '%s|%s' \"$A\" \"$B\""])

      assert out == "it's $HOME `id` \\n|line1\nline2"
    end

    test "hashes change when a value changes and are keyed" do
      h1 = Secrets.hashes(%{"A" => "1"})
      h2 = Secrets.hashes(%{"A" => "2"})
      assert h1["A"] != h2["A"]
      refute h1["A"] == Base.encode16(:crypto.hash(:sha256, "A" <> <<0>> <> "1"), case: :lower)
      assert Secrets.changed_names(h1, h2) == ["A"]
      assert Secrets.changed_names(h1, %{}) == ["A"]
      assert Secrets.changed_names(nil, h1) == ["A"]
    end
  end
end
