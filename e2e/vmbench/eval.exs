# Control plane helpers for the VM isolation benchmark (e2e/vmbench/bench.sh),
# run inside the control plane image:
#   bin/foreman eval 'Code.eval_file("/e2e/vmbench/eval.exs"); Bench.status()'
defmodule Bench do
  import Ecto.Query

  alias Foreman.{Accounts, Boxes, Environments, Operations, Repo, Scope}

  def start, do: {:ok, _} = Application.ensure_all_started(:foreman)

  def admin do
    start()
    Accounts.get_user_by_login("bench") || raise "run the seed first"
  end

  def box(name), do: Repo.one!(from b in Boxes.Box, where: b.name == ^name and is_nil(b.revoked_at))

  # Prints ENV=<id> SLUG=<slug>.
  def create(box_name, cpus, memory_mb, repo \\ "acme/vmbench") do
    scope = Scope.for_user(admin())
    repo = Foreman.Repos.get_repo_by_full_name(repo)

    attrs =
      %{"repo_id" => repo.id, "box_id" => box(box_name).id, "confirm" => "true"}
      |> then(fn a -> if cpus, do: Map.put(a, "cpu_limit", cpus), else: a end)
      |> then(fn a -> if memory_mb, do: Map.put(a, "memory_limit_mb", memory_mb), else: a end)

    case Environments.create_environment(scope, attrs) do
      {:ok, env} -> IO.puts("ENV=#{env.id} SLUG=#{env.slug}")
      {:error, reason} -> IO.puts("REFUSED #{inspect(reason)}")
    end
  end

  # Prints STATE <observed> <desired> and the last op.
  def state(slug) do
    admin()
    env = live_env(slug)
    [op | _] = Operations.list_for_environment(env.id, 1)
    IO.puts("STATE #{env.observed_state} #{env.desired_state} #{op.action} #{op.status}")
  end

  # Prints OP <action> <status> <seconds> for each operation, oldest first.
  def ops(slug) do
    admin()
    env = live_env(slug)

    for op <- env.id |> Operations.list_for_environment(100) |> Enum.reverse() do
      secs =
        if op.started_at && op.finished_at,
          do: DateTime.diff(op.finished_at, op.started_at, :millisecond) / 1000,
          else: nil

      IO.puts("OP #{op.action} #{op.status} #{secs} #{inspect(op.error)}")
    end
  end

  def log(slug) do
    admin()
    env = live_env(slug)
    [op | _] = Operations.list_for_environment(env.id, 1)
    IO.puts(Operations.log(op))
  end

  def act(slug, action) do
    scope = Scope.for_user(admin())
    env = live_env(slug)

    {:ok, _} =
      case action do
        "stop" -> Environments.stop(scope, env)
        "start" -> Environments.start(scope, env)
        "destroy" -> Environments.destroy(scope, env)
        "restart_all" -> Environments.restart(scope, env, :all)
        "restart_affected" -> Environments.restart(scope, env, :affected)
        "rebuild" -> Environments.rebuild(scope, env)
      end

    IO.puts("queued #{action} for #{slug}")
  end

  def secret(slug, name, value) do
    scope = Scope.for_user(admin())
    env = live_env(slug)
    {:ok, _} = Foreman.Secrets.put_secret(scope, "environment", env, %{"name" => name, "value" => value})
    IO.puts("set #{name} on #{slug}")
  end

  def status do
    admin()

    for box <- Repo.all(from b in Boxes.Box, where: is_nil(b.revoked_at)) do
      IO.puts("BOX #{box.name} agent=#{box.agent_version} seen=#{box.last_seen_at}")
    end

    for env <- Repo.all(from e in Foreman.Environments.Environment, where: is_nil(e.destroyed_at)) do
      IO.puts("ENV #{env.slug} desired=#{env.desired_state} observed=#{env.observed_state}")
    end
  end

  defp live_env(slug) do
    Repo.one!(from e in Foreman.Environments.Environment, where: e.slug == ^slug and is_nil(e.destroyed_at))
  end
end
