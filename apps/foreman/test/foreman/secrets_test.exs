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

      for name <- ["PATH", "LD_PRELOAD", "FOREMAN_X", "1ABC", "A-B", "a b", "DOCKER_HOST"] do
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
