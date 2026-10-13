defmodule Foreman.Environments do
  @moduledoc """
  Environments: creating them, the actions users take on them, and keeping
  what's on each box in line with what users asked for.

  Every action becomes a queued operation. `Foreman.Environments.Server`
  sends an environment's operations to its box one at a time; results come
  back through `apply_result/1`. When a box reconnects (after a reboot,
  say) its inventory is reconciled against each environment's desired
  state: stopped ones that should run get their secrets and a start,
  missing ones are recreated.

  When secrets change, running environments get the new files right away
  (new shells see them), are marked *pending restart*, and the user picks
  Restart affected, Restart all, or Later.
  """
  import Ecto.Query

  alias Foreman.Boxes.Box
  alias Foreman.Environments.{Environment, Server}
  alias Foreman.Repos.Repo, as: GitRepo
  alias Foreman.{Audit, Capacity, Operations, Repo, Scope, Secrets}

  require Logger

  @preloads [:box, :user, repo: :owner]

  # -- queries ----------------------------------------------------------------------

  def list_environments(%Scope{} = scope) do
    query =
      from e in Environment,
        where: is_nil(e.destroyed_at),
        order_by: [asc: e.slug],
        preload: ^@preloads

    query =
      if Scope.admin?(scope),
        do: query,
        else: where(query, [e], e.user_id == ^Scope.user_id(scope))

    Repo.all(query)
  end

  def get_environment!(%Scope{} = scope, id) do
    env = Environment |> Repo.get!(id) |> Repo.preload(@preloads)

    if env.user_id == Scope.user_id(scope) or Scope.admin?(scope),
      do: env,
      else: raise(Ecto.NoResultsError, queryable: Environment)
  end

  def get!(id), do: Environment |> Repo.get!(id) |> Repo.preload(@preloads)

  def live_for_box(box_id) do
    from(e in Environment,
      where: e.box_id == ^box_id and is_nil(e.destroyed_at),
      preload: ^@preloads
    )
    |> Repo.all()
  end

  def live_ids_for_box(box_id) do
    Repo.all(
      from e in Environment, where: e.box_id == ^box_id and is_nil(e.destroyed_at), select: e.id
    )
  end

  def live_slugs,
    do: Repo.all(from e in Environment, where: is_nil(e.destroyed_at), select: e.slug)

  def subscribe(env_id), do: Phoenix.PubSub.subscribe(Foreman.PubSub, "environment:" <> env_id)
  def subscribe_all, do: Phoenix.PubSub.subscribe(Foreman.PubSub, "environments")

  # -- create ------------------------------------------------------------------------

  @doc """
  Creates an environment and queues its creation on the box.

  Returns `{:confirm, message}` when the box's policy is `warn` and the
  placement is past capacity (pass `"confirm" => "true"` to go ahead),
  and `{:error, message}` when the policy refuses it.
  """
  def create_environment(%Scope{user: user} = scope, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, repo} <- fetch_repo(attrs["repo_id"]),
         {:ok, box} <- fetch_box(scope, attrs["box_id"]),
         limits = %{
           cpu_limit: number(attrs["cpu_limit"]),
           memory_limit_mb: integer(attrs["memory_limit_mb"])
         },
         :ok <- check_placement(box, repo, limits, attrs["confirm"] in ["true", true]) do
      branch = blank(attrs["branch"]) || repo.default_branch
      insert_environment(scope, user, repo, box, branch, limits)
    end
  end

  defp fetch_repo(id) when is_binary(id) do
    case Repo.get(GitRepo, id) do
      %GitRepo{devcontainer_path: nil} -> {:error, "that repo has no devcontainer"}
      %GitRepo{} = repo -> {:ok, Repo.preload(repo, :owner)}
      nil -> {:error, "pick a repo"}
    end
  end

  defp fetch_repo(_), do: {:error, "pick a repo"}

  defp fetch_box(scope, id) when is_binary(id) do
    case Repo.get(Box, id) do
      %Box{} = box ->
        if Box.usable_by?(box, scope.user),
          do: {:ok, box},
          else: {:error, "you can't use that box"}

      nil ->
        {:error, "pick a box"}
    end
  end

  defp fetch_box(_, _), do: {:error, "pick a box"}

  defp check_placement(box, repo, limits, confirmed?) do
    case Capacity.check_placement(box, live_for_box(box.id), repo, limits) do
      :ok -> :ok
      {:contention, _} -> :ok
      {:warn, _} when confirmed? -> :ok
      {:warn, message} -> {:confirm, message}
      {:refuse, message} -> {:error, message}
    end
  end

  defp insert_environment(scope, user, repo, box, branch, limits, attempt \\ 0) do
    {slug, index} = next_slug(repo, user)

    changeset =
      Environment.create_changeset(
        %Environment{},
        Map.merge(limits, %{
          slug: slug,
          index: index,
          repo_id: repo.id,
          user_id: user.id,
          box_id: box.id,
          branch: branch
        })
      )

    case Repo.insert(changeset) do
      {:ok, env} ->
        Audit.log(scope, "environment.create", env, %{
          "slug" => slug,
          "repo" => repo.full_name,
          "box" => box.name
        })

        enqueue(env, "create", %{}, user)
        broadcast_list()
        {:ok, Repo.preload(env, @preloads, force: true)}

      {:error, %Ecto.Changeset{errors: [slug: _]}} when attempt < 3 ->
        insert_environment(scope, user, repo, box, branch, limits, attempt + 1)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  The next free slug: `<repo>-<n>` on personal deployments,
  `<repo>-<login>-<n>` on team ones. Destroyed environments free their
  numbers.
  """
  def next_slug(repo, user) do
    team? = Foreman.Config.slug_style() == :team
    prefix = slug_prefix(repo.name, if(team?, do: user.login))

    query =
      from e in Environment,
        where: e.repo_id == ^repo.id and is_nil(e.destroyed_at),
        select: e.index

    query = if team?, do: where(query, [e], e.user_id == ^user.id), else: query
    used = MapSet.new(Repo.all(query))
    index = Enum.find(Stream.iterate(1, &(&1 + 1)), &(not MapSet.member?(used, &1)))

    {"#{prefix}-#{index}", index}
  end

  defp slug_prefix(name, login) do
    clean = fn s ->
      s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    end

    parts = [clean.(name) |> String.slice(0, 40), login && clean.(login) |> String.slice(0, 15)]
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("-")
  end

  # -- actions -----------------------------------------------------------------------

  def start(scope, env), do: action(scope, env, :start)
  def stop(scope, env), do: action(scope, env, :stop)
  def rebuild(scope, env), do: action(scope, env, :rebuild)
  def destroy(scope, env), do: action(scope, env, :destroy)
  def restart(scope, env, :affected), do: action(scope, env, :restart_affected)
  def restart(scope, env, :all), do: action(scope, env, :restart_all)
  def git_status(scope, env), do: action(scope, env, :git_status)

  @doc "Runs the create again, for an environment whose first create failed."
  def retry(scope, env), do: action(scope, env, :create)

  def logs(scope, env, service \\ nil) do
    action(scope, env, :logs, %{"service" => service, "tail" => 300})
  end

  @doc "\"Later\": leaves the pending-restart badge and notice in place. Nothing to do."
  def restart_later(_scope, env), do: {:ok, env}

  defp action(%Scope{} = scope, %Environment{} = env, action, args \\ %{}) do
    with :ok <- authorize(scope, env),
         :ok <- allowed?(env, action) do
      desired =
        case action do
          :stop -> "stopped"
          :destroy -> "destroyed"
          a when a in [:create, :start, :rebuild, :restart_affected, :restart_all] -> "running"
          _ -> env.desired_state
        end

      env =
        if desired != env.desired_state,
          do: update_env!(env, %{desired_state: desired}),
          else: env

      args =
        if action == :restart_affected,
          do: Map.put(args, "changed", env.pending_changes),
          else: args

      if action == :start, do: enqueue(env, "secrets_write", %{}, scope.user)
      op = enqueue(env, Atom.to_string(action), args, scope.user)
      Audit.log(scope, "environment.#{action}", env)
      {:ok, op}
    end
  end

  defp authorize(scope, env) do
    if env.user_id == Scope.user_id(scope) or Scope.admin?(scope),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp allowed?(%Environment{destroyed_at: nil}, _action), do: :ok
  defp allowed?(_env, _action), do: {:error, "the environment has been destroyed"}

  @doc false
  def enqueue(env, action, args, user) do
    existing =
      Repo.one(
        from o in Foreman.Operations.Operation,
          where: o.environment_id == ^env.id and o.action == ^action and o.status == "queued",
          limit: 1
      )

    op =
      existing ||
        Operations.create!(%{
          id: Ecto.UUID.generate(),
          environment_id: env.id,
          box_id: env.box_id,
          user_id: user && user.id,
          action: action,
          command: command_type(action),
          args: args
        })

    Server.kick(env.id)
    op
  end

  defp command_type("create"), do: "env.create"
  defp command_type("rebuild"), do: "env.rebuild"
  defp command_type("start"), do: "env.start"
  defp command_type("stop"), do: "env.stop"
  defp command_type("destroy"), do: "env.destroy"
  defp command_type("restart_affected"), do: "env.restart"
  defp command_type("restart_all"), do: "env.restart"
  defp command_type("secrets_write"), do: "env.secrets.write"
  defp command_type("git_status"), do: "env.git_status"
  defp command_type("logs"), do: "env.logs"

  def update_limits(%Scope{} = scope, %Environment{} = env, attrs) do
    with :ok <- authorize(scope, env),
         {:ok, env} <- env |> Environment.limits_changeset(attrs) |> Repo.update() do
      broadcast(env)
      {:ok, env}
    end
  end

  # -- results -----------------------------------------------------------------------

  @doc "Applies a finished operation's outcome to its environment, then sends the next one."
  def apply_result(%Foreman.Operations.Operation{environment_id: nil}), do: :ok

  def apply_result(%Foreman.Operations.Operation{} = op) do
    env = Repo.get!(Environment, op.environment_id)
    attrs = result_attrs(op, env)
    env = if attrs == %{}, do: env, else: update_env!(env, attrs)

    if op.action == "destroy" and op.status == "succeeded" do
      %{"slug" => env.slug} |> Foreman.Jobs.CleanupTailnet.new() |> Oban.insert()
    end

    Server.kick(env.id)
    :ok
  end

  @up ~w(create rebuild start restart_affected restart_all)

  defp result_attrs(%{status: "succeeded", action: action, result: result} = op, _env)
       when action in @up do
    result = result || %{}

    base = %{
      observed_state: "running",
      status_message: nil,
      created_once: true,
      pending_restart: false,
      pending_changes: []
    }

    base
    |> put_if(:applied_secret_hashes, op.args["secret_hashes"])
    |> put_if(:token_pushed_at, if(op.args["token"], do: DateTime.utc_now()))
    |> put_if(:remote_user, result["remote_user"])
    |> put_if(:workspace_folder, result["remote_workspace_folder"])
    |> put_if(:services, result["services"])
    |> put_if(:devcontainer_service, result["devcontainer_service"])
    |> put_if(:warnings, result["warnings"])
    |> put_if(:host_requirements, result["host_requirements"])
    |> then(&if(action in ["create", "rebuild"], do: Map.put(&1, :ts_authkey, nil), else: &1))
  end

  defp result_attrs(%{status: "succeeded", action: "stop"}, _env),
    do: %{observed_state: "stopped", status_message: nil}

  defp result_attrs(%{status: "succeeded", action: "destroy"}, _env),
    do: %{observed_state: "destroyed", destroyed_at: DateTime.utc_now(), status_message: nil}

  defp result_attrs(%{status: "succeeded", action: "secrets_write"} = op, _env) do
    if op.args["token"], do: %{token_pushed_at: DateTime.utc_now()}, else: %{}
  end

  defp result_attrs(%{status: status, action: action, error: error}, _env)
       when status in ["failed", "cancelled"] and action in @up do
    %{observed_state: "error", status_message: error || status}
  end

  defp result_attrs(%{status: status, action: action, error: error}, _env)
       when status in ["failed", "cancelled"] and action in ["stop", "destroy", "secrets_write"] do
    %{status_message: "#{action} failed: #{error || status}"}
  end

  defp result_attrs(_op, _env), do: %{}

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc false
  def update_env!(env, attrs) do
    env = env |> Environment.state_changeset(attrs) |> Repo.update!()
    broadcast(env)
    env
  end

  @doc "The transitional state shown while an operation runs."
  def transitional_state("create"), do: "creating"
  def transitional_state("rebuild"), do: "creating"
  def transitional_state("start"), do: "starting"
  def transitional_state("restart_affected"), do: "starting"
  def transitional_state("restart_all"), do: "starting"
  def transitional_state("stop"), do: "stopping"
  def transitional_state("destroy"), do: "destroying"
  def transitional_state(_), do: nil

  # -- secrets -----------------------------------------------------------------------

  @doc """
  Called after secrets change. Running environments whose resolved secrets
  differ from what they last started with get the new files now and are
  marked pending restart, with the changed names recorded for Restart
  affected.
  """
  def secrets_changed(env_ids) do
    for env <- Repo.all(from e in Environment, where: e.id in ^env_ids and is_nil(e.destroyed_at)),
        env.created_once do
      current = env |> Secrets.resolve() |> Secrets.hashes()
      changed = Secrets.changed_names(env.applied_secret_hashes, current)

      env =
        if changed == [],
          do: update_env!(env, %{pending_restart: false, pending_changes: []}),
          else: update_env!(env, %{pending_restart: true, pending_changes: changed})

      if env.desired_state == "running", do: enqueue(env, "secrets_write", %{}, nil)
    end

    :ok
  end

  @doc "Pushes fresh files (and a fresh GitHub token) to every running environment of `user_id`, or all."
  def push_secrets(opts \\ []) do
    query =
      from e in Environment,
        where: is_nil(e.destroyed_at) and e.desired_state == "running" and e.created_once

    query =
      case opts[:user_id] do
        nil -> query
        id -> where(query, [e], e.user_id == ^id)
      end

    query =
      case opts[:older_than] do
        nil -> query
        cutoff -> where(query, [e], is_nil(e.token_pushed_at) or e.token_pushed_at < ^cutoff)
      end

    for env <- Repo.all(query), do: enqueue(env, "secrets_write", %{}, nil)
    :ok
  end

  # -- reconciliation ------------------------------------------------------------------

  @doc """
  Compares a box's inventory with what its environments should be, and
  queues what's needed to match. Environments with an operation in flight
  are left alone, as are ones in an error state (so a failing start
  doesn't loop).
  """
  def reconcile_inventory(box_id, inventory) do
    by_id = Map.new(inventory, &{&1.env_id, &1})
    envs = live_for_box(box_id)
    known = MapSet.new(envs, & &1.id)

    orphans = for inv <- inventory, not MapSet.member?(known, inv.env_id), do: inv.slug
    Phoenix.PubSub.broadcast(Foreman.PubSub, "boxes", {:orphans, box_id, orphans})
    :persistent_term.put({__MODULE__, :orphans, box_id}, orphans)

    for env <- envs, not Operations.active?(env.id) do
      observed = if inv = by_id[env.id], do: inv.state, else: "missing"

      env =
        if observed != env.observed_state and env.observed_state != "error",
          do: update_env!(env, %{observed_state: observed}),
          else: env

      reconcile(env, observed)
    end

    :ok
  end

  def orphans(box_id), do: :persistent_term.get({__MODULE__, :orphans, box_id}, [])

  defp reconcile(%Environment{observed_state: "error"}, _observed), do: :ok

  defp reconcile(%Environment{desired_state: "running"} = env, "stopped") do
    Logger.info("starting #{env.slug} to match its desired state")
    enqueue(env, "secrets_write", %{}, nil)
    enqueue(env, "start", %{}, nil)
  end

  defp reconcile(%Environment{desired_state: "running", created_once: true} = env, "missing") do
    Logger.info("recreating #{env.slug}: it's missing from its box")
    enqueue(env, "create", %{}, nil)
  end

  defp reconcile(%Environment{desired_state: "stopped"} = env, observed)
       when observed in ["running", "partial"] do
    enqueue(env, "stop", %{}, nil)
  end

  defp reconcile(%Environment{desired_state: "destroyed"} = env, _observed),
    do: enqueue(env, "destroy", %{}, nil)

  defp reconcile(_env, _observed), do: :ok

  @doc "Records a state change an agent noticed (a container stopped, say)."
  def observe(box_id, env_id, state) do
    case Repo.get(Environment, env_id) do
      %Environment{box_id: ^box_id, destroyed_at: nil} = env ->
        unless Operations.active?(env.id) or env.observed_state == state,
          do: update_env!(env, %{observed_state: state})

        :ok

      _ ->
        {:error, :not_yours}
    end
  end

  # -- helpers ----------------------------------------------------------------------

  defp broadcast(env) do
    Phoenix.PubSub.broadcast(Foreman.PubSub, "environment:" <> env.id, {:environment, env.id})
    broadcast_list()
  end

  defp broadcast_list,
    do: Phoenix.PubSub.broadcast(Foreman.PubSub, "environments", :environments_changed)

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(v), do: v

  defp number(nil), do: nil
  defp number(""), do: nil
  defp number(v) when is_number(v), do: v

  defp number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp integer(nil), do: nil
  defp integer(""), do: nil
  defp integer(v) when is_integer(v), do: v

  defp integer(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> nil
    end
  end
end
