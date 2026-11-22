defmodule ForemanWeb.SetupControllerTest do
  use ForemanWeb.ConnCase
  alias Foreman.Jobs.SyncRepos

  test "installation queues a new sync after a recent periodic scan", %{conn: conn} do
    {:ok, prior} = SyncRepos.new(%{}) |> Oban.insert()
    prior |> Ecto.Changeset.change(state: "completed") |> Foreman.Repo.update!()
    assert redirected_to(get(conn, ~p"/setup/github/installed")) == ~p"/sign-in"
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 2
  end
end
