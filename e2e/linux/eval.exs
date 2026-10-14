# Helpers the Linux end-to-end run calls inside the control plane image:
#   bin/foreman eval 'Code.eval_file("/e2e/linux/eval.exs"); E2E.status()'
defmodule E2E do
  import Ecto.Query

  alias Foreman.{Accounts, Boxes, Environments, Operations, Repo, Scope}

  def start, do: {:ok, _} = Application.ensure_all_started(:foreman)

  def admin do
    start()
    Accounts.get_user_by_login("e2e") || raise "run the seed first"
  end

  def box, do: Repo.one!(from b in Boxes.Box, where: is_nil(b.revoked_at), limit: 1)

  def create do
    scope = Scope.for_user(admin())
    repo = Foreman.Repos.get_repo_by_full_name("acme/hello")
    {:ok, env} = Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box().id})
    IO.puts("ENV=#{env.id} SLUG=#{env.slug}")
  end

  def status do
    admin()
    box = box()

    IO.puts("BOX #{box.name} agent=#{box.agent_version} seen=#{box.last_seen_at}")

    for env <- Repo.all(from e in Foreman.Environments.Environment, order_by: e.inserted_at) do
      IO.puts("ENV #{env.slug} desired=#{env.desired_state} observed=#{env.observed_state} msg=#{inspect(env.status_message)}")

      for op <- Operations.list_for_environment(env.id, 5) do
        IO.puts("  OP #{op.action} #{op.status} #{op.error}")
      end
    end
  end

  def log(slug) do
    admin()
    env = Repo.get_by!(Foreman.Environments.Environment, slug: slug)
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
      end

    IO.puts("queued #{action} for #{slug}")
  end

  def secret(slug, name, value) do
    scope = Scope.for_user(admin())
    env = live_env(slug)
    {:ok, _} = Foreman.Secrets.put_secret(scope, "environment", env, %{"name" => name, "value" => value})
    IO.puts("set #{name} on #{slug}")
  end

  defp live_env(slug) do
    Repo.one!(from e in Foreman.Environments.Environment, where: e.slug == ^slug and is_nil(e.destroyed_at))
  end

  def desire_version(version) do
    admin()
    box = box()
    box |> Ecto.Changeset.change(desired_agent_version: version) |> Repo.update!()
    IO.puts("desired agent version #{version}")
  end
end
