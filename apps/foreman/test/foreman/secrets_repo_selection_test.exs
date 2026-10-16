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

  test "Replace on the secrets page starts from the secret's repos", %{user: user, prod: prod} do
    {:ok, view, _} = live(log_in(build_conn(), user), ~p"/secrets")

    html =
      view |> element("button[phx-click=edit][phx-value-name=PROD_DEPLOY_KEY]") |> render_click()

    assert html =~
             ~r/<option[^>]*selected[^>]*value="#{prod.id}"|<option[^>]*value="#{prod.id}"[^>]*selected/

    view
    |> form("#user-secrets-form",
      secret: %{name: "PROD_DEPLOY_KEY", value: "v2", repo_ids: [prod.id]}
    )
    |> render_submit()

    assert repo_ids(user) == [prod.id]
  end
end
