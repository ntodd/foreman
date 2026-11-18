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
    repo = Foreman.Repos.get_repo_by_full_name(System.get_env("E2E_REPO", "acme/hello"))
    {:ok, env} = Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box().id})
    IO.puts("ENV=#{env.id} SLUG=#{env.slug}")
  end

  # Like create/0, but prints the refusal instead of raising.
  def try_create do
    scope = Scope.for_user(admin())
    repo = Foreman.Repos.get_repo_by_full_name(System.get_env("E2E_REPO", "acme/hello"))

    case Environments.create_environment(scope, %{"repo_id" => repo.id, "box_id" => box().id}) do
      {:ok, env} -> IO.puts("ENV=#{env.id} SLUG=#{env.slug}")
      {:error, message} -> IO.puts("REFUSED #{message}")
    end
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

  # The log of the latest operation of one kind (a secrets write can come
  # after the start you're after).
  def log(slug, action) do
    admin()
    env = Repo.get_by!(Foreman.Environments.Environment, slug: slug)
    op = env.id |> Operations.list_for_environment(20) |> Enum.find(&(&1.action == action))
    IO.puts(if op, do: Operations.log(op), else: "no #{action} operation")
  end

  def act(slug, action) do
    scope = Scope.for_user(admin())
    env = live_env(slug)

    {:ok, _} =
      case action do
        "stop" -> Environments.stop(scope, env)
        "suspend" -> Environments.suspend(scope, env)
        "start" -> Environments.start(scope, env)
        "destroy" -> Environments.destroy(scope, env)
      end

    IO.puts("queued #{action} for #{slug}")
  end

  # Runs an environment's failed operation again, as the page's Retry
  # (a create) or Start would.
  def retry_failed(slug) do
    scope = Scope.for_user(admin())
    env = live_env(slug)
    [op | _] = Operations.list_for_environment(env.id, 1)

    {:ok, _} =
      case op.action do
        "create" -> Environments.retry(scope, env)
        _ -> Environments.start(scope, env)
      end

    IO.puts("retried #{op.action} for #{slug}")
  end

  # The latest logs operation's id, before asking for another (through
  # the environment page, in the running control plane: one queued from
  # an eval waits for something there to notice it).
  def last_logs(slug) do
    admin()
    IO.puts("LAST=#{latest_logs(slug) |> then(&(&1 && &1.id)) || "none"}")
  end

  # Waits for a logs operation newer than `previous` to finish, and prints it.
  def await_logs(slug, previous, seconds \\ 180) do
    admin()
    op = latest_logs(slug)

    cond do
      op && op.id != previous && Foreman.Operations.Operation.finished?(op) ->
        IO.puts("LOGS #{op.status}")
        IO.puts(Operations.log(op))

      seconds <= 0 ->
        IO.puts("LOGS #{(op && op.id != previous && op.status) || "never asked for"}")

      true ->
        Process.sleep(1000)
        await_logs(slug, previous, seconds - 1)
    end
  end

  defp latest_logs(slug) do
    env = live_env(slug)
    env.id |> Operations.list_for_environment(20) |> Enum.find(&(&1.action == "logs"))
  end

  def repo_id do
    admin()
    IO.puts("REPO_ID=#{Foreman.Repos.get_repo_by_full_name(System.get_env("E2E_REPO", "acme/hello")).id}")
  end

  # The prebuild a click on the repo's page started (the box's connection
  # is in the running control plane, which an eval can't reach).
  def latest_prebuild do
    admin()

    case Repo.one(from p in Foreman.Prebuilds.Prebuild, order_by: [desc: p.inserted_at], limit: 1) do
      nil -> IO.puts("no prebuild")
      prebuild -> IO.puts("PREBUILD=#{prebuild.id}")
    end
  end

  def prebuild_status(id) do
    admin()
    prebuild = Repo.get!(Foreman.Prebuilds.Prebuild, id)
    IO.puts("PREBUILD #{prebuild.status} size_mb=#{prebuild.size_mb}")

    if prebuild.status == "failed" do
      IO.puts(prebuild.error)
      IO.puts(Operations.log(Operations.get(prebuild.op_id)))
    end
  end

  # How long an environment's operation of one kind took on the box, from
  # when the agent took it (not how long it waited in the queue).
  def took(slug, action) do
    admin()
    env = Repo.get_by!(Foreman.Environments.Environment, slug: slug)
    op = env.id |> Operations.list_for_environment(20) |> Enum.find(&(&1.action == action))
    IO.puts("TOOK #{DateTime.diff(op.finished_at, op.started_at || op.dispatched_at)}")
  end

  def secret(slug, name, value) do
    scope = Scope.for_user(admin())
    env = live_env(slug)
    {:ok, _} = Foreman.Secrets.put_secret(scope, "environment", env, %{"name" => name, "value" => value})
    IO.puts("set #{name} on #{slug}")
  end

  # An environment made on its page (see e2e/vm/run.sh's create_env).
  def env_id(slug) do
    admin()
    IO.puts("ENV=#{live_env(slug).id}")
  end

  defp live_env(slug) do
    Repo.one!(from e in Foreman.Environments.Environment, where: e.slug == ^slug and is_nil(e.destroyed_at))
  end

  def revoke do
    scope = Scope.for_user(admin())
    box = box()
    {:ok, _} = Boxes.revoke(scope, box)
    IO.puts("revoked #{box.name}")
  end

  # A signed session cookie for the e2e admin, for e2e/lv-click.mjs.
  def session_cookie do
    token = Accounts.create_session(admin(), "e2e")
    opts = Plug.Session.init(ForemanWeb.Endpoint.session_options())

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, ForemanWeb.Endpoint.config(:secret_key_base))
      |> Plug.Session.call(opts)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(:session_token, token)
      |> Plug.Conn.send_resp(200, "")

    [cookie | _] = Plug.Conn.get_resp_header(conn, "set-cookie")
    IO.puts("COOKIE=" <> (cookie |> String.split(";") |> hd()))
  end

  # The box's reboot report, as the agent last sent it.
  def reboot_status do
    admin()
    box = box()

    IO.puts(
      "REBOOT required=#{box.reboot_required} can_restart=#{box.can_restart} " <>
        "boot=#{box.boot_id} packages=#{Enum.join(box.reboot_packages, ",")}"
    )
  end

  # Whether the box can run environment VMs, as its agent last said.
  def vm_status do
    admin()
    vm = box().vm || %{}

    IO.puts(
      "VM ready=#{vm["ready"]} nested=#{vm["nested"]} reflink=#{vm["reflink"]} reason=#{inspect(vm["reason"])}"
    )
  end

  def box_id do
    admin()
    IO.puts("BOX_ID=#{box().id}")
  end

  def desire_version(version) do
    admin()
    box = box()
    box |> Ecto.Changeset.change(desired_agent_version: version) |> Repo.update!()
    IO.puts("desired agent version #{version}")
  end
end
