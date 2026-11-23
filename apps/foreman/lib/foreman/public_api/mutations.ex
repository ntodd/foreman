defmodule Foreman.PublicAPI.Mutations do
  @moduledoc """
  Accepts an authenticated environment request. The receipt and its effects
  commit together. Only the winner wakes the normal agent dispatcher.
  """
  import Ecto.Query

  alias Foreman.{Audit, Boxes, Capacity, Environments, Repo, Scope, Tailscale}
  alias Foreman.Environments.{Environment, Server}
  alias Foreman.Jobs.EnvironmentExpiry
  alias Foreman.OAuth.Principal
  alias Foreman.Operations.Retention
  alias Foreman.PublicAPI.{Access, MutationInput, Receipt}

  @not_found {:error, :resource_not_found, "Resource not found."}
  @no_box {:error, :no_provisionable_boxes, "You have no provisionable boxes."}
  @conflict {:error, :lifecycle_conflict,
             "An opposing lifecycle action or due expiry prevents this action."}

  def create(%Principal{} = actor, key, params) do
    with :ok <- MutationInput.key(key),
         {:ok, input} <- MutationInput.create(params) do
      hash = Receipt.key_hash(actor, "environments", key)

      case Repo.get(Receipt, hash) do
        nil -> place(actor, hash, input)
        receipt -> replay(actor, receipt, input, :create)
      end
    end
  end

  def operate(%Principal{} = actor, id, key, params) do
    with :ok <- MutationInput.key(key),
         {:ok, input} <- MutationInput.action(params),
         {:ok, id} <- path_id(id),
         visible = Access.environments(actor, id),
         %Environment{} = env <- Repo.one(visible),
         :ok <- permit(actor, input["action"]) do
      hash = Receipt.key_hash(actor, "environments/#{id}/operations", key)

      Receipt.reserve(hash, input, fn ->
        # Boot admission shares the same box lock as every other reservation.
        lock_box(env.box_id)

        query =
          if actor.kind == :service_account, do: Access.environments(actor, id), else: visible

        case locked_one(query) do
          nil -> @not_found
          current -> operate_locked(actor, current, input)
        end
      end)
      |> finish(actor, input, :operate)
    else
      nil -> @not_found
      error -> error
    end
  end

  defp place(actor, hash, input) do
    repo_query = Access.repos(actor, input["repo_id"])

    with :ok <- visible(repo_query),
         :ok <- explicit_box_visible(actor, input["box_id"]),
         :ok <- create_scopes(actor, input) do
      explicit = input["box_id"]
      ids = candidates(actor, explicit)
      names = Tailscale.taken_names()

      # Each attempt holds at most one box lock. Its failed admission rolls
      # back the receipt and releases the lock before trying the next box.
      Enum.reduce_while(ids, @no_box, fn id, _ ->
        result =
          Receipt.reserve(hash, input, fn ->
            reserve_on_box(actor, id, repo_query, input, names)
          end)

        case result do
          {:error, {:placement, _error}} when is_nil(explicit) -> {:cont, @no_box}
          {:error, {:placement, error}} -> {:halt, error}
          other -> {:halt, finish(other, actor, input, :create)}
        end
      end)
    else
      error ->
        # Another request may have accepted this key before admission changed.
        # Resolve its receipt under the same unique key as a placement attempt.
        Receipt.reserve(hash, input, fn -> error end) |> finish(actor, input, :create)
    end
  end

  defp reserve_on_box(actor, id, repo_query, input, names) do
    box = lock_box(id)
    # Personal repository access has already been checked with GitHub. A
    # service installation's local grant may change between candidates.
    query =
      if actor.kind == :service_account,
        do: Access.repos(actor, input["repo_id"]),
        else: repo_query

    repo = Repo.one(query)

    with :ok <- new_policy(input["expiry"]),
         :ok <- usable_repo(repo),
         :ok <- admission(actor, box, repo, input) do
      create_on(actor, repo, box, input, names)
    end
  end

  defp candidates(_actor, id) when is_binary(id), do: [id]

  defp candidates(actor, nil) do
    ids =
      from(b in Access.boxes(actor),
        order_by: [
          desc:
            fragment(
              "CASE WHEN ? = ? THEN 1 ELSE 0 END",
              b.owner_user_id,
              type(^actor.user.id, :binary_id)
            ),
          asc: b.name,
          asc: b.id
        ],
        select: b.id
      )
      |> Repo.all()

    # Even an empty pool must check for a concurrently accepted receipt and
    # report invalid expiry before it reports a placement failure.
    if ids == [], do: [nil], else: ids
  end

  defp lock_box(nil), do: nil
  defp lock_box(id), do: locked_one(from b in Foreman.Boxes.Box, where: b.id == ^id)

  defp locked_one(query),
    do: Repo.one(if Repo.sqlite?(), do: query, else: lock(query, "FOR UPDATE"))

  defp explicit_box_visible(_actor, nil), do: :ok

  defp explicit_box_visible(actor, id) do
    visible(from b in Access.boxes(actor), where: b.id == ^id)
  end

  defp visible(query), do: if(Repo.exists?(query), do: :ok, else: @not_found)

  defp usable_repo(nil), do: @not_found

  defp usable_repo(%{devcontainer_path: nil}),
    do: {:error, :invalid_request, "The repository has no devcontainer."}

  defp usable_repo(_), do: :ok

  defp admission(_actor, nil, _repo, _input), do: {:placement, @not_found}

  defp admission(actor, box, repo, input) do
    with :ok <- explicit_box_visible(actor, box.id),
         :ok <- box_ready(box),
         :ok <-
           capacity(Capacity.check_placement(box, Environments.live_for_box(box.id), repo), input) do
      :ok
    else
      error -> {:placement, error}
    end
  end

  defp box_ready(box) do
    cond do
      not Boxes.online?(box.id) ->
        {:error, :box_offline, "The selected box is offline."}

      Boxes.vm_problem(box) ->
        {:error, message} = Boxes.check_vm(box)
        {:error, :box_vm_unavailable, message}

      not match?(%{"ready" => true}, box.vm) ->
        {:error, :box_vm_unavailable, "The selected box has not confirmed VM support."}

      true ->
        :ok
    end
  end

  defp capacity({:warn, _}, %{"confirm_capacity_warning" => true}), do: :ok
  defp capacity({:warn, message}, _), do: {:error, :capacity_confirmation_required, message}
  defp capacity({:refuse, message}, _), do: {:error, :capacity_exceeded, message}
  defp capacity(:ok, _), do: :ok
  defp capacity({:contention, _}, _), do: :ok

  defp create_on(actor, repo, box, input, names) do
    branch = input["branch"] || repo.default_branch

    expiry = input["expiry"]

    attrs = %{
      api_grant_id: actor.grant_id,
      expiry_at: expiry && deadline(expiry),
      expiry_action: expiry && expiry["action"]
    }

    case Environments.insert_environment(actor.user, repo, box, branch, attrs, names) do
      {:ok, env} ->
        op =
          Environments.queue_operation(env, "create", %{}, actor.user,
            api_grant_id: actor.grant_id
          )

        EnvironmentExpiry.schedule!(env)

        Audit.log(
          actor.user,
          "environment.create",
          env,
          Map.merge(audit(actor), %{
            "slug" => env.slug,
            "repo" => repo.full_name,
            "box" => box.name
          })
        )

        {:accept, env.id, op.id}

      {:error, %Ecto.Changeset{}} ->
        {:error, :invalid_request, "The environment could not be reserved."}
    end
  end

  defp new_policy(nil), do: :ok

  defp new_policy(expiry) do
    if DateTime.after?(deadline(expiry), DateTime.utc_now()),
      do: :ok,
      else: {:error, :invalid_request, "The expiry must be in the future."}
  end

  defp deadline(%{"at" => at}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(at)
    datetime
  end

  defp operate_locked(actor, env, %{"action" => action} = input) do
    active = Repo.all(Environments.active_lifecycle(env.id))
    due = EnvironmentExpiry.due?(env)

    cond do
      env.destroyed_at && action != "destroy" ->
        @not_found

      due && action != env.expiry_action ->
        @conflict

      due ->
        {:ok, op} = EnvironmentExpiry.reserve(env)
        accepted_existing(actor, env, action, op.id)

      Enum.any?(active, &(target(&1.action) != target(action))) ->
        @conflict

      active != [] ->
        accepted_existing(actor, env, action, hd(active).id)

      stable?(env, action) ->
        accepted_existing(actor, env, action, nil)

      true ->
        with :ok <- admit_action(env, input) do
          {:ok, op} =
            Environments.queue_action(
              Scope.for_user(actor.user),
              env,
              String.to_existing_atom(action),
              %{},
              api_grant_id: actor.grant_id,
              audit: audit(actor),
              dedupe: false
            )

          {:accept, env.id, op.id}
        end
    end
  end

  defp accepted_existing(actor, env, action, op_id) do
    Audit.log(
      actor.user,
      "environment.#{action}",
      env,
      Map.put(audit(actor), "existing_operation_id", op_id)
    )

    {:accept, env.id, op_id}
  end

  defp target("destroy"), do: "destroyed"
  defp target("stop"), do: "stopped"
  defp target("suspend"), do: "suspended"
  defp target(_), do: "running"

  defp stable?(%{destroyed_at: at}, "destroy"), do: not is_nil(at)

  defp stable?(env, action),
    do:
      env.observed_state == target(action) and env.desired_state == target(action) and
        Foreman.Agents.LifecycleState.confirmed?(env, target(action))

  defp admit_action(env, %{"action" => "start"} = input) do
    env = Repo.preload(env, [:box, :repo])

    with :ok <- box_ready(env.box),
         do: capacity(Capacity.check_start(env, Environments.live_for_box(env.box_id)), input)
  end

  defp admit_action(_, _), do: :ok

  defp finish({:ok, {:accepted, id, op}}, _actor, _input, _endpoint) do
    unless Repo.in_transaction?() do
      if op, do: Server.kick(id)
      Environments.broadcast(%{id: id})
    end

    {:ok, id, op}
  end

  defp finish({:ok, {:replay, receipt}}, actor, input, endpoint),
    do: replay(actor, receipt, input, endpoint)

  defp finish({:error, reason}, _actor, _input, _endpoint), do: reason

  defp replay(actor, receipt, input, endpoint) do
    with %Environment{} = env <- Repo.one(Access.environments(actor, receipt.environment_id)),
         :ok <-
           if(endpoint == :create,
             do: create_scopes(actor, input),
             else: permit(actor, input["action"])
           ) do
      cond do
        receipt.input != input ->
          {:error, :idempotency_conflict, "This key was accepted with different input."}

        endpoint == :create and not is_nil(env.destroyed_at) ->
          {:error, :original_environment_gone, "Original environment gone."}

        receipt.operation_id &&
            not Repo.exists?(
              from(o in Retention.history(DateTime.utc_now()),
                where: o.id == ^receipt.operation_id
              )
            ) ->
          {:history_expired, env.id, receipt.operation_id}

        true ->
          {:ok, env.id, receipt.operation_id}
      end
    else
      nil -> @not_found
      error -> error
    end
  end

  defp create_scopes(actor, input) do
    with :ok <- permit(actor, "create") do
      if expiry = input["expiry"], do: permit(actor, expiry["action"]), else: :ok
    end
  end

  defp permit(actor, action) do
    if "environments:#{action}" in actor.scopes,
      do: :ok,
      else:
        {:error, :insufficient_scope,
         "This connection lacks permission to #{action} environments."}
  end

  defp audit(actor),
    do: %{
      "client_id" => actor.client_id,
      "grant_id" => actor.grant_id,
      "actor_kind" => to_string(actor.kind),
      "trigger" => "request"
    }

  defp path_id(id) do
    case MutationInput.uuid(id) do
      {:ok, id} -> {:ok, id}
      _ -> @not_found
    end
  end
end
