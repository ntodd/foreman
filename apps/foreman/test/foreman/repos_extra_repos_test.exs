defmodule Foreman.ReposExtraReposTest do
  @moduledoc """
  Extra repos set on an owner reach every one of its repos' scoped tokens,
  on top of each repo's own: a devcontainer feature every repo shares can
  clone the private repo it needs without each repo listing it.
  """
  use Foreman.DataCase

  import Ecto.Query

  alias Foreman.{Repos, Scope}

  defp with_extra_repos(struct, repos),
    do: struct |> Ecto.Changeset.change(extra_repos: repos) |> Repo.update!()

  test "a repo's token reaches its own extra repos, then its owner's" do
    owner = owner_fixture(login: "acme") |> with_extra_repos(["shared-config", "design-system"])
    repo = repo_fixture(owner: owner, name: "storefront") |> with_extra_repos(["design-system"])

    assert Repos.extra_repos(repo) == ["design-system", "shared-config"]
    assert Repos.token_repos(repo) == ["storefront", "design-system", "shared-config"]
  end

  test "another owner's extra repos don't apply" do
    owner_fixture(login: "globex") |> with_extra_repos(["globex-config"])
    repo = repo_fixture(owner: owner_fixture(login: "acme"), name: "storefront")

    assert Repos.token_repos(repo) == ["storefront"]
  end

  test "works from a repo whose owner isn't loaded" do
    owner = owner_fixture(login: "acme") |> with_extra_repos(["shared-config"])
    repo = repo_fixture(owner: owner, name: "storefront")

    assert Repos.token_repos(Repo.get!(Foreman.Repos.Repo, repo.id)) ==
             ["storefront", "shared-config"]
  end

  describe "setting an owner's extra repos" do
    setup do
      %{
        owner: owner_fixture(login: "acme"),
        admin: Scope.for_user(user_fixture(role: "admin")),
        member: Scope.for_user(user_fixture())
      }
    end

    test "an admin sets them from a list, and it's audited", ctx do
      assert {:ok, owner} =
               Repos.update_owner_extra_repos(
                 ctx.admin,
                 ctx.owner,
                 "shared-config, design-system"
               )

      assert owner.extra_repos == ["shared-config", "design-system"]

      assert %{metadata: %{"extra_repos" => ["shared-config", "design-system"]}} =
               Repo.one!(
                 from e in Foreman.Audit.Event,
                   where: e.action == "owner.extra_repos" and e.subject_id == ^ctx.owner.id
               )
    end

    test "an empty list clears them", ctx do
      {:ok, _} = Repos.update_owner_extra_repos(ctx.admin, ctx.owner, "shared-config")
      assert {:ok, %{extra_repos: []}} = Repos.update_owner_extra_repos(ctx.admin, ctx.owner, "")
    end

    test "only admins can", ctx do
      assert {:error, :unauthorized} =
               Repos.update_owner_extra_repos(ctx.member, ctx.owner, "shared-config")

      assert Repo.reload!(ctx.owner).extra_repos == []
    end

    test "names are repos under the owner, not owner/name or anything else", ctx do
      for bad <- ["globex/config", "a b/c", "../x", String.duplicate("x", 101)] do
        assert {:error, %Ecto.Changeset{}} =
                 Repos.update_owner_extra_repos(ctx.admin, ctx.owner, bad)
      end

      assert Repo.reload!(ctx.owner).extra_repos == []
    end
  end
end
