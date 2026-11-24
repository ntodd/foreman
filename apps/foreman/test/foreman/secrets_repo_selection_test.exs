defmodule Foreman.SecretsRepoSelectionTest do
  # Replacing a user secret's value mustn't change which repos it reaches.
  use ForemanWeb.ConnCase

  alias Foreman.{Repo, Scope, Secrets}
  alias Foreman.Secrets.Secret

  setup do
    user = user_fixture()
    prod = repo_fixture()
    other = repo_fixture()

    {:ok, _} =
      Secrets.put_secret(Scope.for_user(user), "user", user, %{
        "name" => "PROD_DEPLOY_KEY",
        "value" => "v1",
        "repo_ids" => [prod.id]
      })

    %{user: user, prod: prod, other: other}
  end

  defp repo_ids(user),
    do: Repo.get_by!(Secret, scope_key: "user:#{user.id}", name: "PROD_DEPLOY_KEY").repo_ids

  test "a new value without repo_ids keeps the selection", %{user: user, prod: prod, other: other} do
    other_env = environment_fixture(user: user, repo: other)

    {:ok, _} =
      Secrets.put_secret(Scope.for_user(user), "user", user, %{
        "name" => "PROD_DEPLOY_KEY",
        "value" => "v2"
      })

    assert repo_ids(user) == [prod.id]
    refute Map.has_key?(Secrets.resolve(other_env), "PROD_DEPLOY_KEY")
  end

  test "an explicit empty selection still widens to every repo", %{user: user} do
    {:ok, _} =
      Secrets.put_secret(Scope.for_user(user), "user", user, %{
        "name" => "PROD_DEPLOY_KEY",
        "value" => "v2",
        "repo_ids" => []
      })

    assert repo_ids(user) == []
  end

  defp repo_box(repo, state),
    do:
      "#user-secrets-form input[type=checkbox][name='secret[repo_ids][]'][value='#{repo.id}']#{state}"

  test "Replace on the secrets page starts from the secret's repos", %{
    user: user,
    prod: prod,
    other: other
  } do
    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")

    view |> element("button[phx-click=edit][phx-value-name=PROD_DEPLOY_KEY]") |> render_click()

    assert has_element?(view, repo_box(prod, "[checked]"))
    assert has_element?(view, repo_box(other, ":not([checked])"))

    view |> form("#user-secrets-form", secret: %{value: "v2"}) |> render_submit()
    assert repo_ids(user) == [prod.id]
  end

  test "the repos on the secrets page are checkboxes, one per repo", %{
    user: user,
    prod: prod,
    other: other
  } do
    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")

    refute has_element?(view, "#user-secrets-form select")
    assert has_element?(view, "#user-secrets-form fieldset legend", "Only for these repos")
    assert has_element?(view, "#user-secrets-form label", other.full_name)
    assert has_element?(view, repo_box(prod, ":not([checked])"))
    assert has_element?(view, repo_box(other, ":not([checked])"))

    view
    |> form("#user-secrets-form", secret: %{name: "NEW_KEY", value: "v", repo_ids: [other.id]})
    |> render_submit()

    assert Repo.get_by!(Secret, scope_key: "user:#{user.id}", name: "NEW_KEY").repo_ids ==
             [other.id]
  end

  # Columns cut an owner/name short enough that the repos couldn't be told
  # apart. Each gets a row of its own, and a long name wraps.
  test "each repo has a row to itself and its whole name", %{user: user, prod: prod} do
    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")

    assert has_element?(view, "#user-secrets--repos ul > li > label", prod.full_name)
    refute has_element?(view, "#user-secrets--repos [class*='grid-cols']")
    refute has_element?(view, "#user-secrets--repos .truncate")
  end

  # The list scrolls once it's long, so what's checked mustn't start out of sight.
  test "Replace lists the secret's repos first", %{user: user, prod: prod} do
    for n <- 1..3, do: repo_fixture(owner: owner_fixture(login: "aaa#{n}"))
    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")

    refute has_element?(view, "#user-secrets--repos li:first-child input[value='#{prod.id}']")
    view |> element("button[phx-click=edit][phx-value-name=PROD_DEPLOY_KEY]") |> render_click()

    assert has_element?(
             view,
             "#user-secrets--repos li:first-child input[value='#{prod.id}'][checked]"
           )
  end

  # A secret's row has the component's id and its name for an id. A name
  # can't hold two hyphens, so that's what keeps the group's id apart.
  test "a secret named repos doesn't share an id with the checkboxes", %{user: user} do
    {:ok, _} =
      Secrets.put_secret(Scope.for_user(user), "user", user, %{"name" => "repos", "value" => "v"})

    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")

    assert has_element?(view, "li#user-secrets-repos")
    assert has_element?(view, "fieldset#user-secrets--repos")
    refute has_element?(view, "fieldset#user-secrets-repos")
  end

  # An unchecked box sends nothing, and a save that names no repos keeps
  # the ones the secret has. Clearing every box still has to widen it.
  test "Replace with every box cleared makes the secret for all repos", %{user: user} do
    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")
    view |> element("button[phx-click=edit][phx-value-name=PROD_DEPLOY_KEY]") |> render_click()

    view
    |> form("#user-secrets-form", secret: %{value: "v2", repo_ids: [""]})
    |> render_submit()

    assert repo_ids(user) == []
  end

  # The page lists repos with a devcontainer. One that's lost its
  # devcontainer since had no option to keep selected, so Replace sent no
  # repos at all, which means every repo.
  describe "Replace when the secret's repo isn't listed any more" do
    defp lose_devcontainer(repo),
      do: repo |> Ecto.Changeset.change(devcontainer_path: nil) |> Repo.update!()

    defp replace(user) do
      {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")
      view |> element("button[phx-click=edit][phx-value-name=PROD_DEPLOY_KEY]") |> render_click()
      view |> form("#user-secrets-form", secret: %{value: "v2"}) |> render_submit()
    end

    test "keeps it", %{user: user, prod: prod} do
      lose_devcontainer(prod)
      replace(user)
      assert repo_ids(user) == [prod.id]
    end

    test "keeps it when no repo is listed at all", %{user: user, prod: prod, other: other} do
      lose_devcontainer(prod)
      lose_devcontainer(other)
      replace(user)
      assert repo_ids(user) == [prod.id]
    end
  end
end
