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
  alias Foreman.{Agents, Audit, Capacity, GitHub, Operations, Repo, Scope, Secrets}

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

  @doc "The box's live environments, id => slug."
  def live_slugs_for_box(box_id) do
    Repo.all(
      from e in Environment,
        where: e.box_id == ^box_id and is_nil(e.destroyed_at),
        select: {e.id, e.slug}
    )
    |> Map.new()
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

  Slugs are unique across every repo (they're tailnet hostnames), so the
  numbering is shared by everything with the same prefix: two repos
  called `api` under different owners get `api-1` and `api-2`.
  """
  def next_slug(repo, user) do
    team? = Foreman.Config.slug_style() == :team
    prefix = slug_prefix(repo.name, if(team?, do: user.login))

    # The prefix is only [a-z0-9-], so it has no LIKE wildcards in it.
    used =
      Repo.all(
        from e in Environment,
          where: is_nil(e.destroyed_at) and like(e.slug, ^"#{prefix}-%"),
          select: e.slug
      )
      |> Enum.flat_map(fn slug ->
        case Integer.parse(String.replace_prefix(slug, prefix <> "-", "")) do
          {n, ""} -> [n]
          _ -> []
        end
      end)
      |> MapSet.new()

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

  @doc """
  A git status for comparing the clone with its branch: unaudited, since
  the environment page asks for one whenever it opens.
  """
  def check_branch(%Scope{} = scope, %Environment{} = env) do
    with :ok <- authorize(scope, env),
         :ok <- allowed?(env, :git_status) do
      {:ok, enqueue(env, "git_status", %{}, scope.user)}
    end
  end

  @doc "Runs the create again, for an environment whose first create failed."
  def retry(scope, env), do: action(scope, env, :create)

  def logs(scope, env, service \\ nil) do
    action(scope, env, :logs, %{"service" => service, "tail" => 300})
  end

  @doc """
  How the clone compares with its branch on GitHub, from a git status the
  agent reported: `%{behind: n, ahead: n}`, or `%{other_branch: name}`
  when the clone has another branch checked out.

  HEAD is compared when GitHub has it. When it doesn't (commits that were
  never pushed), the merge base with the clone's upstream is compared
  instead, and the agent's own count of those commits (`ahead`) added:
  close, though a stale upstream can make it overcount.
  """
  def branch_sync(%Environment{} = env, %{} = status) do
    head = sha(status["head"])
    base = sha(status["base"])
    local = if is_integer(status["ahead"]) and status["ahead"] >= 0, do: status["ahead"], else: 0

    cond do
      status["branch"] != env.branch ->
        {:ok, %{other_branch: status["branch"]}}

      is_nil(head) ->
        {:error, :no_head}

      true ->
        env = Repo.preload(env, :repo)

        case GitHub.compare(env.repo, head, env.branch) do
          {:ok, counts} ->
            {:ok, %{behind: counts.ahead_by, ahead: counts.behind_by}}

          {:error, :not_found} when not is_nil(base) and base != head ->
            with {:ok, counts} <- GitHub.compare(env.repo, base, env.branch) do
              {:ok, %{behind: counts.ahead_by, ahead: local + counts.behind_by}}
            end

          error ->
            error
        end
    end
  end

  # Whatever runs in the environment answers for its git.
  defp sha(value) when is_binary(value) do
    if value =~ ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, do: value
  end

  defp sha(_), do: nil

  @doc "\"Later\": leaves the pending-restart badge and notice in place. Nothing to do."
  def restart_later(_scope, env), do: {:ok, env}

  @doc """
  Stops one of the environment's operations: a queued one is dropped, a
  dispatched or running one is killed on the box. A stopped create or
  start leaves the environment in error, ready to retry or rebuild.
  """
  def cancel_operation(%Scope{} = scope, %Environment{} = env, op_id) do
    with :ok <- authorize(scope, env),
         {:ok, op} <- fetch_operation(env, op_id),
         {:ok, op} <- do_cancel(op, scope) do
      Audit.log(scope, "environment.cancel", env, %{"action" => op.action})
      {:ok, op}
    end
  end

  defp fetch_operation(env, op_id) do
    case Operations.get(op_id) do
      %Foreman.Operations.Operation{environment_id: id} = op when id == env.id -> {:ok, op}
      _ -> {:error, "That operation isn't this environment's."}
    end
  end

  defp do_cancel(%{status: "queued"} = op, scope) do
    case Operations.cancel_queued(op) do
      {:ok, op} ->
        apply_result(op)
        {:ok, op}

      # Sent since it was read: stop it on the box instead.
      {:error, :not_queued} ->
        do_cancel(Operations.get!(op.id), scope)
    end
  end

  defp do_cancel(%{status: status} = op, scope) when status in ["dispatched", "running"] do
    with :ok <- Agents.cancel_operation(op, Scope.user_id(scope)), do: {:ok, op}
  end

  defp do_cancel(_op, _scope), do: {:error, "That operation has already finished."}

  # Actions that start or stop the environment. A newer one replaces a
  # queued one going the other way, so the last click wins.
  @opposing %{
    "start" => ~w(stop),
    "restart_affected" => ~w(stop),
    "restart_all" => ~w(stop),
    "stop" => ~w(start restart_affected restart_all)
  }

  defp action(%Scope{} = scope, %Environment{} = env, action, args \\ %{}) do
    with :ok <- authorize(scope, env),
         :ok <- allowed?(env, action) do
      if action == :destroy and box_revoked?(env),
        do: forget(scope, env),
        else: queue_action(scope, env, action, args)
    end
  end

  defp queue_action(scope, env, action, args) do
    desired =
      case action do
        :stop -> "stopped"
        :destroy -> "destroyed"
        a when a in [:create, :start, :rebuild, :restart_affected, :restart_all] -> "running"
        _ -> env.desired_state
      end

    # Remembered so cancelling the operation can put the wish back.
    args =
      if desired != env.desired_state,
        do: Map.put(args, "prior_desired", env.desired_state),
        else: args

    # What the user saw when they clicked. The command adds anything that
    # changes before it's sent.
    args =
      if action == :restart_affected,
        do: Map.put(args, "changed", env.pending_changes),
        else: args

    env =
      if desired != env.desired_state,
        do: update_env!(env, %{desired_state: desired}),
        else: env

    name = Atom.to_string(action)
    supersede(env, name)

    if action == :start, do: enqueue(env, "secrets_write", %{}, scope.user)

    op = enqueue(env, name, args, scope.user)
    Audit.log(scope, "environment.#{action}", env)
    {:ok, op}
  end

  defp supersede(env, "destroy"), do: cancel_queued(env, &(&1 != "destroy"))

  defp supersede(env, action) do
    case @opposing[action] do
      nil -> :ok
      opposing -> cancel_queued(env, &(&1 in opposing))
    end
  end

  defp cancel_queued(env, which?) do
    for op <-
          Repo.all(
            from o in Foreman.Operations.Operation,
              where: o.environment_id == ^env.id and o.status == "queued"
          ),
        which?.(op.action) do
      Operations.cancel_queued(op)
    end

    :ok
  end

  defp box_revoked?(env) do
    case Repo.get(Box, env.box_id) do
      %Box{revoked_at: nil} -> false
      _ -> true
    end
  end

  # A revoked box can never reconnect, so its environments are marked
  # destroyed here. Whatever is left on the machine is the admin's to
  # clean up.
  defp forget(scope, env) do
    now = DateTime.utc_now()

    {:ok, env} =
      Repo.transact(fn ->
        for op <-
              Repo.all(
                from o in Foreman.Operations.Operation,
                  where:
                    o.environment_id == ^env.id and
                      o.status in ["queued", "dispatched", "running"]
              ) do
          if op.status == "queued",
            do: Operations.cancel_queued(op),
            else: Operations.mark(op, "failed", error: "the box was revoked", finished_at: now)
        end

        {:ok,
         env
         |> Environment.state_changeset(%{
           desired_state: "destroyed",
           observed_state: "destroyed",
           destroyed_at: now,
           status_message: nil
         })
         |> Repo.update!()}
      end)

    %{"slug" => env.slug} |> Foreman.Jobs.CleanupTailnet.new() |> Oban.insert()
    Audit.log(scope, "environment.forget", env, %{"reason" => "box revoked"})
    broadcast(env)
    {:ok, env}
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

  @up ~w(create rebuild start restart_affected restart_all)

  @doc """
  Applies a finished operation's outcome to its environment, then sends
  the next one. For a result from the agent, `Foreman.Agents` records the
  operation and calls `record_result/1` in one transaction, then
  `after_result/2`.
  """
  def apply_result(%Foreman.Operations.Operation{} = op) do
    {:ok, env} = Repo.transact(fn -> {:ok, record_result(op)} end)
    after_result(op, env)
  end

  @doc "Writes a finished operation's outcome to its environment. Returns the environment."
  def record_result(%Foreman.Operations.Operation{environment_id: nil} = op) do
    if op.action == "agent.update" and op.status == "failed",
      do: Agents.Releases.update_failed(op)

    nil
  end

  def record_result(%Foreman.Operations.Operation{} = op) do
    env = Repo.get!(Environment, op.environment_id)

    case result_attrs(op, env) do
      attrs when attrs == %{} -> env
      attrs -> env |> Environment.state_changeset(attrs) |> Repo.update!()
    end
  end

  @doc "What follows a recorded result: tell the UI, clean up, send the next operation."
  def after_result(_op, nil), do: :ok

  def after_result(op, %Environment{} = env) do
    broadcast(env)

    if op.action == "destroy" and op.status == "succeeded" do
      %{"slug" => env.slug} |> Foreman.Jobs.CleanupTailnet.new() |> Oban.insert()
    end

    # Secrets changed while it came up: the files it got are already stale.
    if op.action in @up and op.status == "succeeded" and env.pending_restart and
         env.desired_state == "running",
       do: enqueue(env, "secrets_write", %{}, nil)

    Server.kick(env.id)
    :ok
  end

  defp result_attrs(%{status: "succeeded", action: action} = op, env) when action in @up do
    result = if is_map(op.result), do: op.result, else: %{}
    args = op.args || %{}
    changed = changed_since(args["secret_hashes"], env)

    %{
      observed_state: "running",
      status_message: nil,
      created_once: true,
      pending_restart: changed != [],
      pending_changes: changed
    }
    |> put_if(:applied_secret_hashes, args["secret_hashes"])
    |> put_token_pushed(args)
    # Results carry repo content (devcontainer.json): take only what fits.
    |> put_if(:remote_user, string(result["remote_user"]))
    |> put_if(:workspace_folder, string(result["remote_workspace_folder"]))
    |> put_if(:services, strings(result["services"]))
    |> put_if(:devcontainer_service, string(result["devcontainer_service"]))
    |> put_if(:warnings, strings(result["warnings"]))
    |> put_if(:host_requirements, map(result["host_requirements"]))
    |> then(&if(action in ["create", "rebuild"], do: Map.put(&1, :ts_authkey, nil), else: &1))
  end

  defp result_attrs(%{status: "succeeded", action: "stop"}, _env),
    do: %{observed_state: "stopped", status_message: nil}

  defp result_attrs(%{status: "succeeded", action: "destroy"}, _env),
    do: %{observed_state: "destroyed", destroyed_at: DateTime.utc_now(), status_message: nil}

  defp result_attrs(%{status: "succeeded", action: "secrets_write"} = op, _env),
    do: put_token_pushed(%{}, op.args || %{})

  # Cancelled before it was sent: nothing happened on the box. Only a
  # first create that never ran leaves anything to show (a Retry).
  defp result_attrs(%{status: "cancelled", dispatched_at: nil} = op, env) do
    attrs = revert_desired(op, env)

    if op.action == "create" and not env.created_once,
      do: Map.merge(attrs, %{observed_state: "error", status_message: "cancelled"}),
      else: attrs
  end

  defp result_attrs(%{status: status, action: action, error: error} = op, env)
       when status in ["failed", "cancelled"] and action in @up do
    op
    |> revert_desired(env)
    |> Map.merge(%{observed_state: "error", status_message: error || status})
  end

  # The environment is back where it was before the stop or destroy began.
  # Operations sent by an older control plane didn't record that; those go
  # back to running (where a stop starts from), not to error, so what the
  # box reports next still corrects it and reconcile still looks at it.
  defp result_attrs(%{status: status, action: action, error: error} = op, env)
       when status in ["failed", "cancelled"] and action in ["stop", "destroy"] do
    op
    |> revert_desired(env)
    |> Map.merge(%{
      observed_state: (op.args || %{})["prior_state"] || "running",
      status_message: "#{action} failed: #{error || status}"
    })
  end

  # The box's files may be out of date: the next token refresh sends them again.
  defp result_attrs(%{status: status, action: "secrets_write", error: error}, _env)
       when status in ["failed", "cancelled"],
       do: %{status_message: "secrets_write failed: #{error || status}", token_pushed_at: nil}

  defp result_attrs(_op, _env), do: %{}

  defp changed_since(nil, _env), do: []

  defp changed_since(applied, env),
    do: Secrets.changed_names(applied, env |> Secrets.resolve() |> Secrets.hashes())

  # A cancelled stop means "keep it running": put back the desired state
  # the action replaced, unless something since has changed it again.
  defp revert_desired(%{status: "cancelled", action: action, args: args}, env) do
    case args do
      %{"prior_desired" => prior} when is_binary(prior) ->
        if env.desired_state == desired_for(action), do: %{desired_state: prior}, else: %{}

      _ ->
        %{}
    end
  end

  defp revert_desired(_op, _env), do: %{}

  defp desired_for("stop"), do: "stopped"
  defp desired_for("destroy"), do: "destroyed"
  defp desired_for(action) when action in @up, do: "running"
  defp desired_for(_), do: nil

  defp put_token_pushed(attrs, %{"token" => true}),
    do: Map.put(attrs, :token_pushed_at, DateTime.utc_now())

  # GitHub couldn't give a token just then: first in line for the next refresh.
  defp put_token_pushed(attrs, %{"token_retry" => true}),
    do: Map.put(attrs, :token_pushed_at, nil)

  defp put_token_pushed(attrs, _args), do: attrs

  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil

  defp strings(v) when is_list(v), do: if(Enum.all?(v, &is_binary/1), do: v)
  defp strings(_), do: nil

  defp map(v) when is_map(v), do: v
  defp map(_), do: nil

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
  queues what's needed to match. Environments with a lifecycle operation
  (create, start, stop and so on) queued or in flight are left to it, as
  are ones in an error state (so a failing start doesn't loop). Anything
  else in flight (a secrets write, a logs fetch) doesn't hold it up: the
  agent only reports its inventory again when it changes, so this may be
  the one chance to start the environment after a reboot.
  """
  def reconcile_inventory(box_id, inventory) do
    by_id = Map.new(inventory, &{&1.env_id, &1})
    envs = live_for_box(box_id)
    known = MapSet.new(envs, & &1.id)

    orphans = for inv <- inventory, not MapSet.member?(known, inv.env_id), do: inv.slug
    Phoenix.PubSub.broadcast(Foreman.PubSub, "boxes", {:orphans, box_id, orphans})
    :persistent_term.put({__MODULE__, :orphans, box_id}, orphans)

    for env <- envs, not lifecycle_active?(env.id) do
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

  # A reboot wipes the secrets tmpfs, so files go first. One already on
  # its way is built when it's sent, so it'll do.
  defp reconcile(%Environment{desired_state: "running"} = env, "stopped") do
    Logger.info("starting #{env.slug} to match its desired state")
    unless active_action?(env.id, "secrets_write"), do: enqueue(env, "secrets_write", %{}, nil)
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
        unless lifecycle_active?(env.id) or env.observed_state == state,
          do: update_env!(env, %{observed_state: state})

        :ok

      _ ->
        {:error, :not_yours}
    end
  end

  @lifecycle ~w(create rebuild start stop destroy restart_affected restart_all)

  defp lifecycle_active?(env_id) do
    Repo.exists?(
      from o in Foreman.Operations.Operation,
        where:
          o.environment_id == ^env_id and o.action in @lifecycle and
            o.status in ["queued", "dispatched", "running"]
    )
  end

  defp active_action?(env_id, action) do
    Repo.exists?(
      from o in Foreman.Operations.Operation,
        where:
          o.environment_id == ^env_id and o.action == ^action and
            o.status in ["queued", "dispatched", "running"]
    )
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
