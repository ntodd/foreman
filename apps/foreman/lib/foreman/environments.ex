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
  alias Foreman.Jobs.EnvironmentExpiry
  alias ForemanProtocol.Connect
  alias Foreman.Repos.Repo, as: GitRepo
  alias Foreman.{Activity, Agents, Audit, Capacity, GitHub, Operations, Repo, Scope, Secrets}

  require Logger

  @preloads [:box, :user, repo: :owner]
  @up ~w(create rebuild pull_rebuild start restart_affected restart_all)
  @lifecycle @up ++ ~w(stop suspend destroy)

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
    boots =
      from o in Foreman.Operations.Operation,
        where:
          o.box_id == ^box_id and o.action in @up and
            o.status in ["queued", "dispatched", "running"],
        select: o.environment_id

    from(e in Environment,
      where: e.box_id == ^box_id and is_nil(e.destroyed_at),
      select_merge: %{boot_reserved: type(fragment("?", e.id in subquery(boots)), :boolean)},
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

  @doc "Every recorded tailnet device, as `{device_id, slug, live?}`."
  def recorded_devices do
    Repo.all(
      from e in Environment,
        where: not is_nil(e.tailscale_device_id),
        select: {e.tailscale_device_id, e.slug, is_nil(e.destroyed_at)}
    )
  end

  def subscribe(env_id), do: Phoenix.PubSub.subscribe(Foreman.PubSub, "environment:" <> env_id)
  def subscribe_all, do: Phoenix.PubSub.subscribe(Foreman.PubSub, "environments")

  # -- create ------------------------------------------------------------------------

  @doc """
  Creates an environment and queues its creation on the box.

  Returns `{:confirm, message}` when the box's policy is `warn` and the
  placement is past capacity (pass `"confirm" => "true"` to go ahead),
  and `{:error, message}` when the policy refuses it.
  """
  def create_environment(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, repo} <- fetch_repo(attrs["repo_id"]),
         {:ok, box} <- fetch_box(scope, attrs["box_id"]),
         :ok <- check_vm(box),
         {:ok, env} <- reserve_creation(scope, repo, box, attrs) do
      Audit.log(scope, "environment.create", env, %{
        "slug" => env.slug,
        "repo" => repo.full_name,
        "box" => box.name
      })

      Server.kick(env.id)
      broadcast_list()
      {:ok, Repo.preload(env, @preloads)}
    end
  end

  @doc "Resource overrides used for both placement previews and environment creation."
  def placement_limits(attrs) do
    %{
      cpu_limit: number(attrs["cpu_limit"]),
      memory_limit_mb: integer(attrs["memory_limit_mb"])
    }
  end

  defp reserve_creation(scope, repo, box, attrs) do
    limits = placement_limits(attrs)

    branch = blank(attrs["branch"]) || repo.default_branch
    confirmed? = attrs["confirm"] in ["true", true]
    names = Foreman.Tailscale.taken_names()

    with_box_lock(box.id, fn locked ->
      with :ok <- check_placement(locked, repo, limits, confirmed?),
           {:ok, env} <- insert_environment(scope.user, repo, locked, branch, limits, names) do
        queue_operation(env, "create", %{}, scope.user)
        {:ok, env}
      end
    end)
  end

  # Admission and its reservation must see the same box. SQLite already
  # takes a writer lock at transaction start. Postgres locks just this box.
  defp with_box_lock(id, fun) do
    {:ok, result} =
      Repo.transact(fn ->
        box = from(b in Box, where: b.id == ^id)
        query = if Repo.sqlite?(), do: box, else: lock(box, "FOR UPDATE")
        {:ok, fun.(Repo.one!(query))}
      end)

    result
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

  # Every environment runs in a VM of its own; a box that can't run them
  # gets none.
  defp check_vm(box), do: Foreman.Boxes.check_vm(box)

  defp check_placement(box, repo, limits, confirmed?) do
    placement = Capacity.check_placement(box, live_for_box(box.id), repo, limits)
    placement_decision(placement, confirmed?)
  end

  defp placement_decision(placement, confirmed?) do
    case placement do
      :ok -> :ok
      {:contention, _} -> :ok
      {:warn, _} when confirmed? -> :ok
      {:warn, message} -> {:confirm, message}
      {:refuse, message} -> {:error, message}
    end
  end

  @doc false
  def insert_environment(user, repo, box, branch, limits, names, attempt \\ 0) do
    {slug, index} = next_slug(repo, user, names)

    changeset =
      Environment.create_changeset(
        %Environment{repo_github_id: repo.github_id},
        Map.merge(limits, %{
          slug: slug,
          index: index,
          repo_id: repo.id,
          user_id: user.id,
          box_id: box.id,
          branch: branch
        })
      )

    case Repo.insert(changeset, mode: :savepoint) do
      {:error, %Ecto.Changeset{errors: [slug: _]}} when attempt < 3 ->
        insert_environment(user, repo, box, branch, limits, names, attempt + 1)

      result ->
        result
    end
  end

  @doc """
  The next free slug: `<repo>-<n>` on personal deployments,
  `<repo>-<login>-<n>` on team ones. Destroyed environments free their
  numbers.

  Slugs are unique across every repo (they're tailnet hostnames), so the
  numbering is shared by everything with the same prefix: two repos
  called `api` under different owners get `api-1` and `api-2`. Names
  already on the tailnet (another deployment's, say) are skipped too.
  """
  def next_slug(repo, user), do: next_slug(repo, user, Foreman.Tailscale.taken_names())

  defp next_slug(repo, user, on_tailnet) do
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

    index =
      Enum.find(
        Stream.iterate(1, &(&1 + 1)),
        &(not MapSet.member?(used, &1) and not MapSet.member?(on_tailnet, "#{prefix}-#{&1}"))
      )

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

  def start(scope, env, confirmed? \\ false), do: boot_action(scope, env, :start, confirmed?)

  defp boot_action(scope, env, action, confirmed?) do
    with :ok <- authorize(scope, env),
         {:ok, op} <-
           with_box_lock(env.box_id, fn _box ->
             env = locked_environment(env.id) |> Repo.preload(@preloads)

             with :ok <- allowed?(env, action),
                  :ok <- admit_boot(env, action, confirmed?) do
               queue_action(scope, env, action, %{})
             end
           end) do
      Server.kick(env.id)
      broadcast(env)
      {:ok, op}
    end
  end

  defp admit_boot(%{desired_state: "running"} = env, action, confirmed?) when action != :start do
    if Capacity.allocated?(env), do: :ok, else: admit_start(env, confirmed?)
  end

  defp admit_boot(env, _action, confirmed?), do: admit_start(env, confirmed?)

  defp admit_start(%{observed_state: "running", desired_state: "running"}, _confirmed?), do: :ok

  defp admit_start(env, confirmed?) do
    env |> Capacity.check_start(live_for_box(env.box_id)) |> placement_decision(confirmed?)
  end

  def stop(scope, env), do: action(scope, env, :stop)

  @doc """
  Suspends a running environment: its VM's memory goes to disk and the VM
  stops, and a start resumes it where it was, processes and all.
  """
  def suspend(scope, env), do: action(scope, env, :suspend)
  def rebuild(scope, env, confirmed? \\ false), do: boot_action(scope, env, :rebuild, confirmed?)

  @doc """
  Fast-forwards the clone to its branch, then rebuilds. The agent refuses
  (and leaves the environment running) if the clone has uncommitted
  changes or commits the branch doesn't.
  """
  def pull_rebuild(scope, env, confirmed? \\ false) do
    with :ok <- authorize(scope, env),
         :ok <- can_pull?(env),
         do: boot_action(scope, env, :pull_rebuild, confirmed?)
  end

  # Protocol 3 added `pull` to env.rebuild; an older agent refuses it.
  defp can_pull?(env) do
    case Repo.get(Box, env.box_id) do
      %Box{protocol_version: v} when is_integer(v) and v >= 3 ->
        :ok

      %Box{name: name} ->
        {:error,
         "#{name} needs a newer agent to pull; update its agent, or rebuild without pulling."}

      nil ->
        {:error, "the environment's box is gone"}
    end
  end

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

  @doc """
  Runs an action of one of the environment's connect hooks (see
  `ForemanProtocol.Connect`), such as pairing a client. Its result is
  usually a credential for the environment, so only its owner can ask, and
  the result isn't recorded with the operation: it comes to the calling
  process alone, as `{:connect_offer, op_id, offer}`, subscribed before the
  operation can go out so it can't miss it.
  """
  def connect(%Scope{} = scope, %Environment{} = env, hook, action) do
    cond do
      env.user_id != Scope.user_id(scope) ->
        {:error, :unauthorized}

      not Connect.action?(env.connect_hooks || [], hook, action) ->
        {:error, "#{env.slug} doesn't offer that action."}

      not is_nil(env.destroyed_at) or env.observed_state != "running" ->
        {:error, "#{env.slug} has to be running for that."}

      not Foreman.Boxes.online?(env.box_id) ->
        {:error, "#{env.slug}'s box is offline."}

      true ->
        args = %{"hook" => hook, "action" => action}
        id = Ecto.UUID.generate()
        Phoenix.PubSub.subscribe(Foreman.PubSub, offer_topic(id))
        op = enqueue(env, "connect", args, scope.user, dedupe: false, id: id)
        Audit.log(scope, "environment.connect", env, args)
        {:ok, op}
    end
  end

  @doc "Stops receiving a connect operation's result (see `connect/4`)."
  def unsubscribe_offer(op_id),
    do: Phoenix.PubSub.unsubscribe(Foreman.PubSub, offer_topic(op_id))

  @doc false
  def deliver_offer(op_id, offer),
    do:
      Phoenix.PubSub.broadcast(
        Foreman.PubSub,
        offer_topic(op_id),
        {:connect_offer, op_id, offer}
      )

  defp offer_topic(op_id), do: "connect_offer:" <> op_id

  @doc "Runs the create again, for an environment whose first create failed."
  def retry(scope, env, confirmed? \\ false), do: boot_action(scope, env, :create, confirmed?)

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
      not is_binary(status["branch"]) or status["branch"] == "" ->
        {:error, :invalid_git_status}

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

  # The id comes from the browser; Postgres refuses a non-UUID outright.
  defp fetch_operation(env, op_id) do
    with {:ok, op_id} <- Ecto.UUID.cast(op_id),
         %Foreman.Operations.Operation{environment_id: id} = op when id == env.id <-
           Operations.get(op_id) do
      {:ok, op}
    else
      _ -> {:error, "That operation isn't this environment's."}
    end
  end

  defp do_cancel(%{trigger: "expiry"}, _scope), do: {:error, "Expiry cleanup is pending."}

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
    "start" => ~w(stop suspend),
    "restart_affected" => ~w(stop suspend),
    "restart_all" => ~w(stop suspend),
    "stop" => ~w(start restart_affected restart_all suspend),
    "suspend" => ~w(start restart_affected restart_all stop)
  }

  defp action(%Scope{} = scope, %Environment{} = env, action, args \\ %{}) do
    with :ok <- authorize(scope, env) do
      result =
        with_box_lock(env.box_id, fn box ->
          reserve_user_action(scope, locked_environment(env.id), box, action, args)
        end)

      case result do
        {:forget, env} ->
          forget(scope, env)

        {:ok, op} ->
          Server.kick(env.id)
          {:ok, op}

        error ->
          error
      end
    end
  end

  defp reserve_user_action(scope, env, box, action, args) do
    with :ok <- allowed?(env, action) do
      cond do
        action != :destroy or is_nil(box.revoked_at) ->
          queue_action(scope, env, action, args)

        env.expiry_action == "destroy" and is_nil(env.expiry_consumed_at) ->
          {:error, "Physical deletion is pending on the revoked box."}

        true ->
          {:forget, env}
      end
    end
  end

  @doc false
  def locked_environment(id) do
    query = from e in Environment, where: e.id == ^id
    Repo.one(if Repo.sqlite?(), do: query, else: lock(query, "FOR UPDATE"))
  end

  @doc false
  def queue_action(scope, env, action, args, opts \\ []) do
    desired =
      case action do
        :stop ->
          "stopped"

        # Nothing starts it but a start, and a box that still says it's
        # running is told to suspend it, not stop it.
        :suspend ->
          "suspended"

        :destroy ->
          "destroyed"

        a when a in [:create, :start, :rebuild, :pull_rebuild, :restart_affected, :restart_all] ->
          "running"

        _ ->
          env.desired_state
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

    env = prepare_queue(env, name, opts[:trigger])

    if action == :start and not env.initial_create_deferred,
      do: queue_operation(env, "secrets_write", %{}, scope.user, opts)

    op = queue_operation(env, name, args, scope.user, opts)
    Audit.log(scope, "environment.#{action}", env, Keyword.get(opts, :audit, %{}))
    {:ok, op}
  end

  defp prepare_queue(env, "stop", "expiry") do
    cancelled = cancel_queued(env, &(&1 in @up or &1 == "suspend"))

    if not env.created_once and Enum.any?(cancelled, &(&1.action == "create")),
      do: update_env!(env, %{initial_create_deferred: true}),
      else: env
  end

  defp prepare_queue(env, name, _) do
    supersede(env, name)
    env
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
        which?.(op.action),
        {:ok, cancelled} <- [Operations.cancel_queued(op)],
        do: cancelled
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

        destroyed =
          env
          |> Environment.state_changeset(%{
            desired_state: "destroyed",
            observed_state: "destroyed",
            destroyed_at: now,
            status_message: nil
          })
          |> Repo.update!()

        Secrets.delete_environment_secrets(destroyed)
        {:ok, destroyed}
      end)

    cleanup_tailnet(env)
    Audit.log(scope, "environment.forget", env, %{"reason" => "box revoked"})
    broadcast(env)
    {:ok, env}
  end

  defp authorize(scope, env) do
    if env.user_id == Scope.user_id(scope) or Scope.admin?(scope),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp allowed?(%Environment{destroyed_at: nil} = env, action)
       when action in [
              :create,
              :start,
              :stop,
              :destroy,
              :suspend,
              :rebuild,
              :pull_rebuild,
              :restart_all,
              :restart_affected
            ] do
    if EnvironmentExpiry.due?(env), do: {:error, "Expiry cleanup is pending."}, else: :ok
  end

  defp allowed?(%Environment{destroyed_at: nil}, _action), do: :ok
  defp allowed?(_env, _action), do: {:error, "the environment has been destroyed"}

  @doc false
  def enqueue(env, action, args, user, opts \\ []) do
    op = queue_operation(env, action, args, user, opts)
    Server.kick(env.id)
    op
  end

  @doc false
  def queue_operation(env, action, args, user, opts \\ []) do
    existing =
      Keyword.get(opts, :dedupe, true) &&
        Repo.one(
          from o in Foreman.Operations.Operation,
            where: o.environment_id == ^env.id and o.action == ^action and o.status == "queued",
            limit: 1
        )

    existing ||
      Operations.create!(%{
        id: Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0),
        environment_id: env.id,
        box_id: env.box_id,
        user_id: user && user.id,
        api_grant_id: opts[:api_grant_id],
        trigger: Keyword.get(opts, :trigger, "request"),
        action: action,
        command:
          if(action == "start" and env.initial_create_deferred,
            do: "env.create",
            else: command_type(action)
          ),
        args: args
      })
  end

  defp command_type("create"), do: "env.create"
  defp command_type("rebuild"), do: "env.rebuild"
  defp command_type("pull_rebuild"), do: "env.rebuild"
  defp command_type("start"), do: "env.start"
  defp command_type("stop"), do: "env.stop"
  defp command_type("suspend"), do: "env.suspend"
  defp command_type("destroy"), do: "env.destroy"
  defp command_type("restart_affected"), do: "env.restart"
  defp command_type("restart_all"), do: "env.restart"
  defp command_type("secrets_write"), do: "env.secrets.write"
  defp command_type("git_status"), do: "env.git_status"
  defp command_type("connect"), do: "env.connect"
  defp command_type("logs"), do: "env.logs"

  def update_limits(%Scope{} = scope, %Environment{} = env, attrs, confirmed? \\ false) do
    with :ok <- authorize(scope, env),
         {:ok, updated} <-
           with_box_lock(env.box_id, fn _box ->
             resize(get!(env.id), attrs, confirmed?)
           end) do
      broadcast(updated)
      {:ok, updated}
    end
  end

  defp resize(env, attrs, confirmed?) do
    changeset = Environment.limits_changeset(env, attrs)

    with :ok <- allowed?(env, :resize),
         {:ok, resized} <- Ecto.Changeset.apply_action(changeset, :update),
         placement = Capacity.check_resize(env, resized, live_for_box(env.box_id)),
         :ok <- placement_decision(placement, confirmed?) do
      Repo.update(changeset)
    end
  end

  @doc """
  Whether the environment's box ships a newer Foreman feature than the one
  its container was built with: `{:behind, built, shipped}`, or
  `{:unknown, shipped}` for one built before agents recorded it. Only a
  rebuild updates it. Takes the environment with its box loaded.
  """
  def feature_update(
        %Environment{created_once: true, destroyed_at: nil, box: %Foreman.Boxes.Box{} = box} = env
      ) do
    case {parse_version(env.feature_version), parse_version(box.feature_version)} do
      {_, :error} ->
        nil

      {:error, {:ok, _}} ->
        {:unknown, box.feature_version}

      {{:ok, built}, {:ok, shipped}} ->
        if Version.compare(built, shipped) == :lt,
          do: {:behind, env.feature_version, box.feature_version}
    end
  end

  def feature_update(%Environment{}), do: nil

  defp parse_version(v) when is_binary(v), do: Version.parse(v)
  defp parse_version(_), do: :error

  # -- results -----------------------------------------------------------------------

  @fresh_build ~w(create rebuild pull_rebuild)

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

  @doc """
  Writes a finished operation's outcome to its environment. Returns the
  environment if the result can confirm its state. A superseded expiry result
  returns `:expiry_already_consumed` and leaves the environment alone.
  Box operations return the work left by `Foreman.Prebuilds.record_result/1`.
  """
  def record_result(%Foreman.Operations.Operation{environment_id: nil} = op) do
    if op.action == "agent.update" and op.status == "failed",
      do: Agents.Releases.update_failed(op)

    Foreman.Prebuilds.record_result(op)
  end

  def record_result(%Foreman.Operations.Operation{} = op) do
    record_environment_result(op, locked_environment(op.environment_id))
  end

  # A dispatched retry can finish after its sibling consumed the expiry.
  # Keep its operation history without reapplying its old state or cleanup.
  defp record_environment_result(
         %{
           id: id,
           trigger: "expiry",
           action: "stop",
           status: "succeeded",
           dispatched_at: %DateTime{} = sent
         },
         %{expiry_consumed_at: at, observed_state: "stopped", desired_state: "stopped"} = env
       )
       when not is_nil(at) do
    # The current socket may have performed the redundant stop. Its result
    # confirms only that stop, never a state established by a later action.
    superseded =
      from o in Foreman.Operations.Operation,
        where: o.environment_id == ^env.id and o.id != ^id and o.action in @lifecycle,
        where: o.dispatched_at >= ^sent

    if Repo.exists?(superseded), do: :expiry_already_consumed, else: env
  end

  defp record_environment_result(%{trigger: "expiry"}, %{expiry_consumed_at: at})
       when not is_nil(at),
       do: :expiry_already_consumed

  defp record_environment_result(op, env) do
    attrs = result_attrs(op, env)

    attrs =
      cond do
        is_nil(env.expiry_at) or not is_nil(env.expiry_consumed_at) ->
          attrs

        attrs[:destroyed_at] || (op.trigger == "expiry" and op.status == "succeeded") ->
          # A late physical success can race a queued replacement for its timeout.
          retire_queued_expiry(env.id)
          Map.put(attrs, :expiry_consumed_at, DateTime.utc_now())

        op.trigger == "expiry" ->
          # The failed attempt stays in history. Its replacement must survive a
          # restart and run as system cleanup even after the owner loses access.
          EnvironmentExpiry.retry!(env)
          attrs

        true ->
          attrs
      end

    case attrs do
      attrs when attrs == %{} ->
        env

      attrs ->
        replaced_device(env, attrs[:tailscale_device_id])

        updated = env |> Environment.state_changeset(attrs) |> Repo.update!()
        if attrs[:destroyed_at], do: Secrets.delete_environment_secrets(updated)
        Map.put(updated, :stale_notice, stale_notice?(op, env))
    end
  end

  defp retire_queued_expiry(env_id) do
    from(o in Foreman.Operations.Operation,
      where: o.environment_id == ^env_id and o.trigger == "expiry" and o.status == "queued"
    )
    |> Repo.all()
    |> Enum.each(&Operations.cancel_queued/1)
  end

  # The files on the box were sent with the secrets that applied before
  # this up, so their notice says secrets changed (see
  # `Commands.notices/3`), and this up has just applied them.
  defp stale_notice?(%{status: "succeeded", action: action, args: args}, env)
       when action in @up do
    case args do
      %{"secret_hashes" => hashes} when is_map(hashes) ->
        env.created_once and Secrets.changed_names(env.applied_secret_hashes, hashes) != []

      _ ->
        false
    end
  end

  defp stale_notice?(_op, _env), do: false

  # Came back as a new node (its Tailscale state was lost), so the old
  # device is offline and holding the environment's name.
  defp replaced_device(%Environment{tailscale_device_id: old} = env, new)
       when is_binary(old) and is_binary(new) and old != new do
    %{"slug" => env.slug, "device_id" => old, "replaced_by" => new}
    |> Foreman.Jobs.CleanupTailnet.new()
    |> Oban.insert!()
  end

  defp replaced_device(_env, _new), do: :ok

  defp cleanup_tailnet(env) do
    %{"slug" => env.slug}
    |> put_if("device_id", env.tailscale_device_id)
    |> Foreman.Jobs.CleanupTailnet.new()
    |> Oban.insert()
  end

  @doc "What follows a recorded result: tell the UI, clean up, send the next operation."
  def after_result(_op, nil), do: :ok
  def after_result(_op, {:prebuilds, _, _} = sends), do: Foreman.Prebuilds.after_result(sends)
  def after_result(op, :expiry_already_consumed), do: Server.kick(op.environment_id)

  def after_result(op, %Environment{} = env) do
    broadcast(env)

    if op.action == "destroy" and op.status == "succeeded", do: cleanup_tailnet(env)

    # Secrets changed while it came up, so the files it got are already
    # stale; or it applied secrets its files still say have changed.
    if op.action in @up and op.status == "succeeded" and
         (env.pending_restart or env.stale_notice) and env.desired_state == "running",
       do: enqueue(env, "secrets_write", %{}, nil)

    Server.kick(env.id)
    :ok
  end

  defp result_attrs(%{status: "succeeded", action: action} = op, env) when action in @up do
    result = if is_map(op.result), do: op.result, else: %{}
    args = op.args || %{}
    # A resumed VM's processes carry on with the secrets they had when it
    # was suspended, whatever its files say now.
    args =
      if result["resumed"] == true,
        do: Map.put(args, "secret_hashes", env.applied_secret_hashes),
        else: args

    changed = changed_since(args["secret_hashes"], env)

    %{
      observed_state: "running",
      status_message: nil,
      created_once: true,
      initial_create_deferred: false,
      pending_restart: changed != [],
      pending_changes: changed
    }
    |> put_if(:applied_secret_hashes, args["secret_hashes"])
    |> put_token_pushed(args)
    # Results carry repo content (devcontainer.json): take only what fits.
    |> Map.put(:workspace_container_id, workspace_id(result))
    |> put_if(:remote_user, string(result["remote_user"]))
    |> put_if(:workspace_folder, string(result["remote_workspace_folder"]))
    |> put_if(:services, strings(result["services"]))
    |> put_if(:devcontainer_service, string(result["devcontainer_service"]))
    |> put_if(:warnings, strings(result["warnings"]))
    |> put_if(:host_requirements, map(result["host_requirements"]))
    # Absent from an older agent, which could have built it with anything.
    |> Map.put(:feature_version, version(result["feature_version"]))
    |> put_if(:tailscale_device_id, node_id(result["tailscale_node_id"]))
    # Every up from an agent that runs hooks reports them; one that doesn't
    # is older (a box rolled back) and can't run them.
    |> Map.put(:connect_hooks, connect_hooks(result["connect"]))
    |> then(
      &if(op.command == "env.create" or action in @fresh_build,
        do: Map.put(&1, :ts_authkey, nil),
        else: &1
      )
    )
  end

  # Nothing's running with the old secrets any more; a start picks up
  # whatever is current.
  defp result_attrs(%{status: "succeeded", action: "stop"}, _env),
    do: %{
      observed_state: "stopped",
      vm_size: nil,
      status_message: nil,
      pending_restart: false,
      pending_changes: []
    }

  # Its processes are as they were, with the secrets they had; a start
  # resumes it.
  defp result_attrs(%{status: "succeeded", action: "suspend", result: result}, _env) do
    %{
      observed_state: "suspended",
      status_message: nil,
      vm_size: saved_size((result || %{})["vm_size"])
    }
  end

  defp result_attrs(%{status: "succeeded", action: "destroy"}, _env),
    do: %{
      observed_state: "destroyed",
      desired_state: "destroyed",
      destroyed_at: DateTime.utc_now(),
      status_message: nil
    }

  # A write that works clears the message an earlier failed one left.
  defp result_attrs(%{status: "succeeded", action: "secrets_write"} = op, env) do
    attrs = put_token_pushed(%{}, op.args || %{})

    if is_binary(env.status_message) and
         String.starts_with?(env.status_message, "secrets_write failed"),
       do: Map.put(attrs, :status_message, nil),
       else: attrs
  end

  # Cancelled before it was sent: nothing happened on the box. Only a
  # first create that never ran leaves anything to show (a Retry).
  defp result_attrs(%{status: "cancelled", dispatched_at: nil} = op, env) do
    attrs = revert_desired(op, env)

    if op.action == "create" and not env.created_once,
      do: Map.merge(attrs, %{observed_state: "error", status_message: "cancelled"}),
      else: attrs
  end

  # Refused before anything was torn down, so it's still running (the
  # agent starts a stopped one to pull in it).
  defp result_attrs(
         %{status: "failed", action: "pull_rebuild", result: %{"pull_failed" => true}} = op,
         _env
       ),
       do: %{
         observed_state: "running",
         status_message: "Didn't pull: #{op.error}",
         ts_authkey: nil
       }

  defp result_attrs(%{status: status, action: action, error: error} = op, env)
       when status in ["failed", "cancelled"] and action in @up do
    op
    |> revert_desired(env)
    |> Map.merge(%{
      observed_state: "error",
      status_message: error || status,
      workspace_container_id: nil
    })
    # It never came up, so its next build is a first boot and gets a
    # fresh Tailscale key; this one may have expired by then.
    |> then(
      &if(action in @fresh_build or not env.created_once,
        do: Map.put(&1, :ts_authkey, nil),
        else: &1
      )
    )
  end

  # The environment is back where it was before the stop or destroy began.
  # Operations sent by an older control plane didn't record that; those go
  # back to running (where a stop starts from), not to error, so what the
  # box reports next still corrects it and reconcile still looks at it.
  defp result_attrs(%{status: status, action: action, error: error} = op, env)
       when status in ["failed", "cancelled"] and action in ["stop", "suspend", "destroy"] do
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

  defp workspace_id(%{"container_id" => id}) when is_binary(id) and byte_size(id) in 1..128,
    do: id

  defp workspace_id(_result), do: nil

  defp connect_hooks(hooks) when is_list(hooks), do: Connect.cast_hooks(hooks)
  defp connect_hooks(_), do: []

  defp changed_since(nil, _env), do: []

  defp changed_since(applied, env),
    do: Secrets.changed_names(applied, env |> Secrets.resolve() |> Secrets.hashes())

  # A cancelled stop means "keep it running": put back the desired state
  # the action replaced, unless something since has changed it again.
  # A failed suspend leaves it running, so running is the wish again.
  defp revert_desired(%{status: status, action: action, args: args}, env)
       when status == "cancelled" or (status == "failed" and action == "suspend") do
    case args do
      %{"prior_desired" => prior} when is_binary(prior) ->
        if env.desired_state == desired_for(action), do: %{desired_state: prior}, else: %{}

      _ ->
        %{}
    end
  end

  defp revert_desired(_op, _env), do: %{}

  defp desired_for("stop"), do: "stopped"
  defp desired_for("suspend"), do: "suspended"
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

  defp version(v) when is_binary(v) and byte_size(v) <= 64,
    do: if(match?({:ok, _}, Version.parse(v)), do: v)

  defp version(_), do: nil

  # Tailscale's stable node IDs are short and alphanumeric, and this one
  # ends up in an API path.
  defp node_id(v) when is_binary(v), do: if(v =~ ~r/\A[A-Za-z0-9]{1,64}\z/, do: v)
  defp node_id(_), do: nil

  defp saved_size(%{"cpus" => cpus, "memory_mb" => mb})
       when is_integer(cpus) and cpus > 0 and is_integer(mb) and mb > 0,
       do: %{"cpus" => cpus, "memory_mb" => mb}

  defp saved_size(_), do: nil

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc false
  def update_env!(env, attrs) do
    env = env |> Environment.state_changeset(attrs) |> Repo.update!()
    broadcast(env)
    env
  end

  @doc false
  def mark_dispatch_state(%{trigger: "expiry"}, env, state) do
    # A sibling success can commit after the retry's claim. Serialize this
    # write with consumption on the environment row, including on Postgres.
    query = from e in Environment, where: e.id == ^env.id and is_nil(e.expiry_consumed_at)

    {changed, _} =
      Repo.update_all(query,
        set: [observed_state: state, status_message: nil, updated_at: DateTime.utc_now()]
      )

    if changed == 1, do: broadcast(env)
  end

  def mark_dispatch_state(_op, env, state),
    do: update_env!(env, %{observed_state: state, status_message: nil})

  @doc "The transitional state shown while an operation runs."
  def transitional_state("create"), do: "creating"
  def transitional_state("rebuild"), do: "creating"
  def transitional_state("pull_rebuild"), do: "creating"
  def transitional_state("start"), do: "starting"
  def transitional_state("restart_affected"), do: "starting"
  def transitional_state("restart_all"), do: "starting"
  def transitional_state("stop"), do: "stopping"
  def transitional_state("suspend"), do: "suspending"
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

      # A stopped environment has nothing running to restart; its next
      # start gets the new secrets. A suspended one's processes come back
      # with the secrets they had, so they need the restart too, and the
      # box keeps the new files for the resume.
      live? = env.desired_state in ["running", "suspended"]

      env =
        if changed == [] or not live?,
          do: update_env!(env, %{pending_restart: false, pending_changes: []}),
          else: update_env!(env, %{pending_restart: true, pending_changes: changed})

      if live?, do: enqueue(env, "secrets_write", %{}, nil)
    end

    :ok
  end

  @doc "Pushes fresh files (and a fresh GitHub token) to every running environment of `user_id`, or all."
  def push_secrets(opts \\ []) do
    query =
      from e in Environment,
        where: is_nil(e.destroyed_at) and e.desired_state == "running"

    query =
      if opts[:include_building] do
        builds =
          from o in Foreman.Operations.Operation,
            where: o.action == "create" and o.status in ["queued", "dispatched", "running"],
            select: o.environment_id

        where(query, [e], e.created_once or e.id in subquery(builds))
      else
        where(query, [e], e.created_once)
      end

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

    for env <- Repo.all(query) do
      args = if env.created_once, do: %{}, else: %{"after_first_create" => true}
      enqueue(env, "secrets_write", args, nil)
    end

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

    Enum.each(envs, &reconcile_entry(&1, by_id[&1.id]))
    :ok
  end

  defp reconcile_entry(env, inv) do
    observed = if inv, do: inv.state, else: "missing"
    Agents.LifecycleState.record(env.box_id, env.id, observed)

    size =
      if inv && inv[:vm_size],
        do: %{"cpus" => inv.vm_size.cpus, "memory_mb" => inv.vm_size.memory_mb}

    if lifecycle_active?(env.id) do
      # Inventory changes are only sent once. Keep a boot size even if
      # the operation result hasn't arrived yet.
      if size && size != env.vm_size, do: update_env!(env, %{vm_size: size})
    else
      state = if env.observed_state == "error", do: "error", else: observed

      if state != env.observed_state or size != env.vm_size do
        update_env!(env, %{observed_state: state, vm_size: size})
      end

      unless EnvironmentExpiry.due?(env), do: reconcile(env, observed)
    end
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

  # A box that was told to keep it running, and has it suspended.
  defp reconcile(%Environment{desired_state: "running"} = env, "suspended") do
    Logger.info("resuming #{env.slug} to match its desired state")
    unless active_action?(env.id, "secrets_write"), do: enqueue(env, "secrets_write", %{}, nil)
    enqueue(env, "start", %{}, nil)
  end

  defp reconcile(%Environment{desired_state: "running", created_once: true} = env, "missing") do
    Logger.info("recreating #{env.slug}: it's missing from its box")
    enqueue(env, "create", %{}, nil)
  end

  # Suspended counts: a stop throws away what was saved.
  defp reconcile(%Environment{desired_state: "stopped"} = env, observed)
       when observed in ["running", "partial", "suspended"] do
    enqueue(env, "stop", %{}, nil)
  end

  defp reconcile(%Environment{desired_state: "suspended"} = env, observed)
       when observed in ["running", "partial"] do
    enqueue(env, "suspend", %{}, nil)
  end

  defp reconcile(%Environment{desired_state: "destroyed"} = env, _observed),
    do: enqueue(env, "destroy", %{}, nil)

  defp reconcile(_env, _observed), do: :ok

  @doc "Remembers the most recent VM out-of-memory kill reported by its box."
  def record_vm_oom(box_id, env_id, unix) do
    with {:ok, at} <- DateTime.from_unix(unix) do
      query =
        from e in Environment,
          where: e.id == ^env_id and e.box_id == ^box_id and is_nil(e.destroyed_at),
          where: is_nil(e.last_vm_oom_at) or e.last_vm_oom_at < ^at

      if {1, nil} == Repo.update_all(query, set: [last_vm_oom_at: at]) do
        broadcast(%{id: env_id})
        Activity.out_of_memory(Repo.get!(Environment, env_id), :vm_oom)
      end
    end
  end

  # A VM short of memory loses one process after another. The first is
  # the news; the page keeps the latest.
  @guest_oom_notice_every_s 300

  @doc """
  Remembers the most recent kills by the kernel inside an environment's
  VM (`%{at, processes}`, from its box), which the VM survives. The time
  is the box's, so one ahead of this clock counts as now.
  """
  def record_guest_oom(box_id, env_id, %{at: unix} = kill) do
    processes = kill[:processes] || []

    query =
      from e in Environment,
        where: e.id == ^env_id and e.box_id == ^box_id and is_nil(e.destroyed_at)

    with {:ok, at} <- DateTime.from_unix(unix),
         at = Enum.min([at, DateTime.utc_now(:second)], DateTime),
         %Environment{last_guest_oom_at: last} = env <- Repo.one(query),
         true <- is_nil(last) or DateTime.before?(last, at) do
      Repo.update_all(query,
        set: [last_guest_oom_at: at, last_guest_oom_processes: processes]
      )

      broadcast(env)

      if is_nil(last) or DateTime.diff(at, last) >= @guest_oom_notice_every_s,
        do: Activity.out_of_memory(env, :guest_oom, processes)
    end

    :ok
  end

  @doc "Records a state change an agent noticed (a container stopped, say)."
  def observe(box_id, env_id, state) do
    case Repo.get(Environment, env_id) do
      %Environment{box_id: ^box_id, destroyed_at: nil} = env ->
        Agents.LifecycleState.record(box_id, env_id, state)

        unless lifecycle_active?(env.id) or env.observed_state == state,
          do: update_env!(env, %{observed_state: state})

        :ok

      _ ->
        {:error, :not_yours}
    end
  end

  def lifecycle_operations do
    from o in Foreman.Operations.Operation,
      where: not is_nil(o.environment_id) and o.action in @lifecycle
  end

  def active_lifecycle(env_id) do
    from o in lifecycle_operations(),
      where: o.environment_id == ^env_id and o.status in ["queued", "dispatched", "running"],
      order_by: [asc: o.inserted_at, asc: o.id]
  end

  defp lifecycle_active?(env_id), do: Repo.exists?(active_lifecycle(env_id))

  defp active_action?(env_id, action) do
    Repo.exists?(
      from o in Foreman.Operations.Operation,
        where:
          o.environment_id == ^env_id and o.action == ^action and
            o.status in ["queued", "dispatched", "running"]
    )
  end

  # -- helpers ----------------------------------------------------------------------

  @doc false
  def broadcast(env) do
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
