defmodule Foreman.PublicAPI.AccessTest do
  use Foreman.DataCase

  import Mox

  alias Foreman.GitHub.ClientMock
  alias Foreman.PublicAPI.Access

  setup :verify_on_exit!

  test "owned and shared boxes are visible until the box is revoked or sharing ends" do
    user = user_fixture()
    principal = %{kind: :user, user: user}
    mine = box_fixture(owner_user_id: user.id)
    shared = box_fixture(shared_user_ids: [user.id])
    _other = box_fixture()

    assert ids(Access.boxes(principal)) == Enum.sort([mine.id, shared.id])
    Repo.update!(Ecto.Changeset.change(shared, shared_user_ids: []))
    assert ids(Access.boxes(principal)) == [mine.id]
    Repo.update!(Ecto.Changeset.change(mine, revoked_at: DateTime.utc_now()))
    assert ids(Access.boxes(principal)) == []
  end

  test "GitHub-backed discovery checks the personal token and stable repository identity" do
    github_config()
    user = user_fixture(role: "admin")
    owner = owner_fixture()
    repo = repo_fixture(owner: owner) |> github_id(122)
    _hidden = repo_fixture(owner: owner) |> github_id(123)
    _renamed = repo_fixture(owner: owner) |> github_id(124)

    expect(ClientMock, :list_user_installation_repos, fn token, installation ->
      assert token == user.access_token
      assert installation == owner.installation_id

      {:ok,
       [
         %{"id" => 122, "full_name" => repo.full_name},
         %{"id" => 124, "full_name" => "another/name"}
       ]}
    end)

    assert ids(Access.repos(%{kind: :user, user: user})) == [repo.id]
  end

  test "absence of the GitHub app does not open GitHub repositories to every client" do
    repo_fixture()
    assert ids(Access.repos(%{kind: :user, user: user_fixture()})) == []
  end

  test "environment visibility requires ownership, repo access and box access even after destroy" do
    old = Application.get_env(:foreman, :git_base_url)
    Application.put_env(:foreman, :git_base_url, "http://git.fixture")
    on_exit(fn -> restore(:git_base_url, old) end)

    user = user_fixture()
    principal = %{kind: :user, user: user}
    public_repo = repo_fixture() |> change(private: false) |> Repo.update!()
    mine = environment_fixture(user: user, repo: public_repo)

    tombstone =
      environment_fixture(user: user, repo: public_repo, destroyed_at: DateTime.utc_now())

    _private_repo = environment_fixture(user: user)

    _other_owner =
      environment_fixture(repo: public_repo, box: Repo.get!(Foreman.Boxes.Box, mine.box_id))

    _other_box = environment_fixture(user: user, repo: public_repo, box: box_fixture())
    assert ids(Access.environments(principal)) == Enum.sort([mine.id, tombstone.id])
  end

  test "polling a single environment checks only its repository and conceals other owners" do
    github_config()
    mine = user_fixture()
    principal = %{kind: :user, user: mine}
    repo = repo_fixture() |> github_id(123)
    env = environment_fixture(user: mine, repo: repo)
    other = environment_fixture()

    assert ids(Access.environments(principal, other.id)) == []

    expect(ClientMock, :get_repo, fn token, name ->
      assert token == mine.access_token
      assert name == repo.full_name
      {:ok, %{"id" => 123, "full_name" => name}}
    end)

    assert ids(Access.environments(principal, env.id)) == [env.id]
    expect(ClientMock, :get_repo, fn _, _ -> {:error, :not_found} end)
    assert ids(Access.environments(principal, env.id)) == []
  end

  test "a temporary failure to verify visibility has a retryable API error" do
    github_config()
    repo = repo_fixture()
    principal = %{kind: :user, user: user_fixture()}
    expect(ClientMock, :get_repo, fn _, _ -> {:error, :timeout} end)
    error = assert_raise Access.Unavailable, fn -> Access.repos(principal, repo.id) end
    assert Plug.Exception.status(error) == 503

    assert %{code: "repository_access_unavailable", message: message} =
             ForemanWeb.ErrorJSON.render("503.json", %{reason: error})

    assert message == Exception.message(error)
  end

  defp github_config do
    old = Application.get_env(:foreman, :github_app)

    Application.put_env(:foreman, :github_app, %{
      app_id: "1",
      client_id: "test",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> restore(:github_app, old) end)
  end

  defp restore(key, nil), do: Application.delete_env(:foreman, key)
  defp restore(key, value), do: Application.put_env(:foreman, key, value)
  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()
  defp github_id(repo, id), do: repo |> Ecto.Changeset.change(github_id: id) |> Repo.update!()
end
