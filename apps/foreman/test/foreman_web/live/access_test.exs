defmodule ForemanWeb.AccessTest do
  # LiveViews act with the scope they mounted with, and take ids from
  # events, so both need checking.
  use ForemanWeb.ConnCase

  alias Foreman.{Accounts, Operations, Repo, Scope, Secrets}

  describe "an open page" do
    test "reloads when its user is disabled, and can't act as them" do
      admin = user_fixture(role: "admin")
      member = user_fixture()
      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/secrets")

      {:ok, _} = Accounts.set_disabled(Scope.for_user(admin), member, true)
      assert_redirect(view, ~p"/secrets")

      {:ok, secrets} = Secrets.list_secrets(Scope.for_user(member), "user", member)
      assert secrets == []
    end

    test "reloads when its user is demoted, and loses admin powers" do
      other_admin = user_fixture(role: "admin")
      demoted = user_fixture(role: "admin")
      target = user_fixture()
      {:ok, view, _} = live(log_in(build_conn(), demoted), ~p"/admin/users")

      {:ok, _} = Accounts.set_role(Scope.for_user(other_admin), demoted, "member")
      assert_redirect(view, ~p"/admin/users")

      assert Repo.reload!(target).role == "member"
    end
  end

  test "an environment page won't show another environment's operation log" do
    me = user_fixture()
    other = user_fixture()
    my_env = environment_fixture(user: me)
    their_env = environment_fixture(user: other)

    their_op =
      Operations.create!(%{
        id: Ecto.UUID.generate(),
        environment_id: their_env.id,
        box_id: their_env.box_id,
        user_id: other.id,
        action: "create",
        command: "env.create",
        args: %{},
        status: "failed",
        log: "THEIR-BUILD-OUTPUT"
      })

    {:ok, view, _} = live(log_in(build_conn(), me), ~p"/environments/#{my_env.id}")
    refute render_click(view, "select_op", %{"id" => their_op.id}) =~ "THEIR-BUILD-OUTPUT"
  end

  test "deleting a secret keeps the page up and lists the rest" do
    member = user_fixture()
    scope = Scope.for_user(member)
    {:ok, _} = Secrets.put_secret(scope, "user", member, %{"name" => "A", "value" => "1"})
    {:ok, _} = Secrets.put_secret(scope, "user", member, %{"name" => "B", "value" => "2"})

    {:ok, view, _} = live(log_in(build_conn(), member), ~p"/secrets")
    html = view |> element("button[phx-click=delete][phx-value-name=A]") |> render_click()

    assert html =~ "user-secrets-B"
    refute html =~ "user-secrets-A"
  end
end
