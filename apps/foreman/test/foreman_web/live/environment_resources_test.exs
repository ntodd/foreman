defmodule ForemanWeb.EnvironmentResourcesTest do
  use ForemanWeb.ConnCase

  alias Foreman.{Environments, Operations, Repo, Scope}

  setup :register_and_log_in

  setup %{user: user} do
    repo = repo_fixture(cpu_limit: 4.0)
    box = box_fixture(owner_user_id: user.id)
    %{env: environment_fixture(user: user, repo: repo, box: box), box: box}
  end

  test "sets independent CPU and GiB overrides, and clears them back to defaults", %{
    conn: conn,
    env: env
  } do
    {:ok, view, _} = live(conn, ~p"/environments/#{env.id}")
    assert has_element?(view, "#environment-resources", "4.0 (repo default)")
    assert has_element?(view, "#environment-resources", "Box default")
    edit(view)
    save(view, "8", "8")
    assert %{cpu_limit: 8.0, memory_limit_mb: 8192} = Repo.reload!(env)
    assert has_element?(view, "#environment-resources", "8.0 GiB")
    assert Operations.list_for_environment(env.id) == []
    assert Environments.get!(env.id).repo.cpu_limit == 4.0

    edit(view)
    assert has_element?(view, "#limits_memory_limit_gib[value='8.0']")
    save(view, "", "1.5")
    assert %{cpu_limit: nil, memory_limit_mb: 1536} = Repo.reload!(env)
    edit(view)
    save(view, "", "")
    assert %{cpu_limit: nil, memory_limit_mb: nil} = Repo.reload!(env)
  end

  test "rejects an invalid edit and preserves the persisted limits", %{conn: conn, env: env} do
    {:ok, view, _} = live(conn, ~p"/environments/#{env.id}")
    edit(view)
    save(view, "0", "-1")
    assert has_element?(view, "#environment-limits", "must be greater")
    assert %{cpu_limit: nil, memory_limit_mb: nil} = Repo.reload!(env)
  end

  test "checks the resized environment once and honors the box policy", %{
    conn: conn,
    env: env,
    box: box
  } do
    box |> Ecto.Changeset.change(capacity_policy: "warn", cpu_threshold: 0.5) |> Repo.update!()
    {:ok, view, _} = live(conn, ~p"/environments/#{env.id}")
    edit(view)
    save(view, "8", "8")
    assert Repo.reload!(env).cpu_limit == 8
    edit(view)
    save(view, "10", "8")
    assert has_element?(view, "button[value=true]", "Save anyway")
    assert Repo.reload!(env).cpu_limit == 8

    form(view, "#environment-limits", limits: %{cpu_limit: "10", memory_limit_gib: "8"})
    |> render_submit(%{"confirm" => "true"})

    assert Repo.reload!(env).cpu_limit == 10

    box |> Ecto.Changeset.change(capacity_policy: "refuse") |> Repo.update!()
    edit(view)
    save(view, "12", "8")
    assert Repo.reload!(env).cpu_limit == 10
    save(view, "9", "8")
    assert Repo.reload!(env).cpu_limit == 9
  end

  test "another member cannot change the environment", %{env: env} do
    assert {:error, :unauthorized} =
             Environments.update_limits(Scope.for_user(user_fixture()), env, %{cpu_limit: 8})
  end

  defp edit(view), do: view |> element("#environment-resources button", "Edit") |> render_click()

  defp save(view, cpu, memory) do
    view
    |> form("#environment-limits", limits: %{cpu_limit: cpu, memory_limit_gib: memory})
    |> render_submit()
  end
end
