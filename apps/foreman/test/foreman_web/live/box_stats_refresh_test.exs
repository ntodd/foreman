defmodule ForemanWeb.BoxStatsRefreshTest do
  @moduledoc """
  Every box sends box.stats every 30 seconds, to every open page on the
  "boxes" topic. A page should redraw that box's card, not reload
  everything it shows.
  """
  use ForemanWeb.ConnCase

  alias Foreman.Boxes
  alias Foreman.Capacity.Tracker

  @boxes 6

  setup do
    admin = user_fixture(role: "admin")
    dev = user_fixture()
    owner = owner_fixture()

    boxes =
      for _ <- 1..@boxes do
        box =
          box_fixture(owner_user_id: admin.id)
          |> Ecto.Changeset.change(shared_user_ids: [dev.id])
          |> Foreman.Repo.update!()

        envs =
          for _ <- 1..3,
              do: environment_fixture(box: box, user: dev, repo: repo_fixture(owner: owner))

        {box, envs}
      end

    %{admin: admin, dev: dev, boxes: boxes}
  end

  # Queries `fun` runs in any process, with the tables they read.
  defp queries(fun) do
    parent = self()
    id = "box-stats-#{System.unique_integer()}"

    :telemetry.attach(
      id,
      [:foreman, :repo, :query],
      fn _, _, meta, _ -> send(parent, {:query, id, meta[:source]}) end,
      nil
    )

    fun.()
    :telemetry.detach(id)
    collect(id, [])
  end

  defp collect(id, acc) do
    receive do
      {:query, ^id, source} -> collect(id, [source | acc])
    after
      0 -> acc
    end
  end

  # Pushes `box`'s usage past its capacity, then announces new stats.
  defp overload(box, [env | _]) do
    Tracker.record(box.id, %{
      capacity: %{cpus: 2, memory_mb: 1024},
      environments: %{env.id => %{cpu_percent: 400.0, memory_mb: 4_096}}
    })

    Boxes.record_capacity(box.id, %{cpus: 2, memory_mb: 1024})
  end

  for {name, path, card} <- [
        {"home page", "/", "box-card-"},
        {"boxes page", "/boxes", "box-"}
      ],
      who <- [:admin, :dev] do
    test "the #{name} (#{who}) redraws one card per box.stats",
         %{conn: conn, boxes: boxes} = ctx do
      {:ok, view, _} = live(log_in(conn, ctx[unquote(who)]), unquote(path))
      [{box, envs} | _] = boxes

      sources =
        queries(fn ->
          overload(box, envs)
          render(view)
        end)

      # One box's worth (its row and its environments with their
      # preloads, plus the update that announced it), whatever the number
      # of boxes on the page.
      assert length(sources) <= 8,
             "one box.stats cost #{length(sources)} queries: #{inspect(Enum.frequencies(sources))}"

      # At most the environments' preload; not the page's repo listing.
      assert Enum.count(sources, &(&1 == "repos")) <= 1

      assert view
             |> element("##{unquote(card)}#{box.id}")
             |> render() =~ "Contention"
    end
  end

  test "a box page doesn't re-read its metrics on box.stats", %{
    conn: conn,
    admin: admin,
    boxes: [{box, envs} | _]
  } do
    {:ok, view, _} = live(log_in(conn, admin), ~p"/boxes/#{box.id}?range=7d")

    sources =
      queries(fn ->
        overload(box, envs)
        render(view)
      end)

    refute "box_metrics" in sources
    refute "env_metrics" in sources
    assert render(view) =~ "Contention"
  end

  test "box.stats from a box the page doesn't show costs nothing", %{conn: conn, dev: dev} do
    other = box_fixture(owner_user_id: user_fixture().id)
    {:ok, view, _} = live(log_in(conn, dev), ~p"/")

    assert queries(fn ->
             Boxes.record_capacity(other.id, %{cpus: 8})
             render(view)
           end) == ["boxes"]
  end
end
