defmodule Foreman.Prebuilds do
  @moduledoc """
  Prebuilds (`Foreman.Prebuilds.Prebuild`): an admin has a box build one
  for a repo's default branch and devcontainer config, and new
  environments of the repo on that box, on that branch, start from it
  instead of cloning and building from nothing. Another build replaces it
  once it's ready.

  A prebuild belongs to no one: it clones with an installation token that
  reads the repo and nothing else, and has no one's secrets. So an
  environment starts from one only once its user's own token has shown it
  reads the repo (`Foreman.Environments.Commands`).
  """
  import Ecto.Query

  alias Foreman.{Agents, Boxes, GitHub, Operations, Repo, Repos, Scope, Tailscale}
  alias Foreman.Operations.{Operation, Redactions}
  alias Foreman.Prebuilds.Prebuild
  alias ForemanProtocol.Command

  require Logger

  @default_config ".devcontainer/devcontainer.json"

  def subscribe(repo_id), do: Phoenix.PubSub.subscribe(Foreman.PubSub, topic(repo_id))

  defp topic(repo_id), do: "prebuilds:#{repo_id}"

  defp broadcast(%Prebuild{} = prebuild) do
    Phoenix.PubSub.broadcast(Foreman.PubSub, topic(prebuild.repo_id), {:prebuild, prebuild.id})
  end

  @doc """
  A repo's prebuilds on each box, by box id, as its page shows them: the
  ready ones, the one new environments start from (`ready_id/3`) first,
  then the latest attempt when it isn't one of those (it's building, or
  failed).
  """
  def by_box(repo) do
    from(p in Prebuild, where: p.repo_id == ^repo.id, order_by: [desc: p.inserted_at])
    |> Repo.all()
    |> Enum.group_by(& &1.box_id)
    |> Map.new(fn {box_id, [latest | _] = prebuilds} ->
      ready =
        prebuilds
        |> Enum.filter(&(&1.status == "ready"))
        |> Enum.sort_by(&(&1.built_at || &1.inserted_at), {:desc, DateTime})
        |> Enum.sort_by(&(unused_because(repo, &1) != nil))

      {box_id, if(latest.status == "ready", do: ready, else: ready ++ [latest])}
    end)
  end

  @doc """
  For each of `repos`, on how many of the boxes `box_ids` a new
  environment of its default branch starts from a prebuild, by repo id.
  A repo with none is left out.
  """
  def ready_box_counts([], _box_ids), do: %{}

  def ready_box_counts(repos, box_ids) do
    by_id = Map.new(repos, &{&1.id, &1})

    from(p in Prebuild,
      where: p.repo_id in ^Map.keys(by_id) and p.box_id in ^box_ids and p.status == "ready"
    )
    |> Repo.all()
    |> Enum.filter(&is_nil(unused_because(by_id[&1.repo_id], &1)))
    |> Enum.uniq_by(&{&1.repo_id, &1.box_id})
    |> Enum.frequencies_by(& &1.repo_id)
  end

  @doc """
  Why new environments of `repo`'s default branch won't start from a
  prebuild: `{:config, path}` when it's of a devcontainer config the repo
  no longer uses, `{:branch, branch}` when it's of another branch, and nil
  when they will.
  """
  def unused_because(repo, %Prebuild{} = prebuild) do
    cond do
      prebuild.config_path != config_path(repo) -> {:config, prebuild.config_path}
      prebuild.branch != repo.default_branch -> {:branch, prebuild.branch}
      true -> nil
    end
  end

  @doc "One of a repo's prebuilds."
  def get(repo, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from p in Prebuild, where: p.id == ^id and p.repo_id == ^repo.id)
      :error -> nil
    end
  end

  @doc "The ids of every prebuild the control plane knows on a box, whatever its status."
  def ids_on_box(box_id),
    do: Repo.all(from p in Prebuild, where: p.box_id == ^box_id, select: p.id)

  @doc "The id of the ready prebuild a new environment of `repo` on a box and branch starts from."
  def ready_id(repo, box_id, branch) do
    with %Prebuild{id: id} <- ready(repo, box_id, branch), do: id
  end

  @doc "The ready prebuild a new environment of `repo` on a box and branch starts from."
  def ready(repo, box_id, branch) do
    config_path = config_path(repo)

    Repo.one(
      from p in Prebuild,
        where:
          p.repo_id == ^repo.id and p.box_id == ^box_id and p.branch == ^branch and
            p.config_path == ^config_path and p.status == "ready",
        order_by: [desc: p.built_at],
        limit: 1
    )
  end

  @doc """
  Has `box` build a prebuild of `repo`'s default branch. The prebuild is
  `building` until the box reports back (`record_result/1`).
  """
  def build(%Scope{} = scope, repo, box) do
    box = Boxes.get_box(box.id) || box
    repo = Repo.preload(repo, :owner)

    prebuild = %Prebuild{
      id: Ecto.UUID.generate(),
      repo_id: repo.id,
      box_id: box.id,
      branch: repo.default_branch,
      config_path: config_path(repo),
      repos: Repos.token_repos(repo)
    }

    # The command is made before anything is recorded, and the prebuild and
    # its operation are recorded together, so nothing that fails on the way
    # leaves a prebuild building with nothing to finish it (which would
    # block every build after it).
    with :ok <- check_build(scope, repo, box),
         {:ok, cmd, redact} <- build_command(repo, prebuild),
         {:ok, {prebuild, op}} <- reserve_build(scope, repo, box, prebuild, cmd) do
      Redactions.put_values(op.id, redact)
      send_build(box, prebuild, op, cmd)
    end
  end

  defp reserve_build(scope, repo, box, prebuild, cmd) do
    Repo.transact(fn ->
      row = from b in Boxes.Box, where: b.id == ^box.id, select: b.id
      Repo.one!(if Repo.sqlite?(), do: row, else: lock(row, "FOR UPDATE"))

      if building?(repo, box) do
        {:error, "A prebuild is already building on this box."}
      else
        op =
          Operations.create!(%{
            id: cmd.op_id,
            box_id: box.id,
            user_id: Scope.user_id(scope),
            action: "box.prebuild",
            command: "box.prebuild",
            args: %{"prebuild_id" => prebuild.id, "repo" => repo.full_name},
            status: "dispatched",
            dispatched_at: DateTime.utc_now()
          })

        {:ok, {Repo.insert!(%{prebuild | op_id: op.id}), op}}
      end
    end)
  end

  defp check_build(scope, repo, box) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      is_nil(repo.devcontainer_path) -> {:error, "The repo has no devcontainer."}
      building?(repo, box) -> {:error, "A prebuild is already building on this box."}
      not Boxes.online?(box.id) -> {:error, "The box is offline."}
      true -> Boxes.check_vm(box)
    end
  end

  defp building?(repo, box) do
    Repo.exists?(
      from p in Prebuild,
        where: p.repo_id == ^repo.id and p.box_id == ^box.id and p.status == "building"
    )
  end

  # The command, and the values to redact from what the build logs.
  defp build_command(repo, prebuild) do
    token = token(repo)

    payload =
      %{
        prebuild_id: prebuild.id,
        repo: repo.full_name,
        clone_url: "#{Foreman.Config.git_base_url()}/#{repo.full_name}.git",
        branch: prebuild.branch,
        config_path: prebuild.config_path,
        files: if(token, do: %{"github-token" => token}, else: %{}),
        # What the repo's environments get, less the key: the Foreman
        # feature's layer then matches theirs.
        tailscale: %{enabled: Tailscale.configured?()},
        # And the size of VM they get, so it builds as they would.
        limits: limits(repo)
      }
      |> put_registry_auth(repo.owner)

    case Command.new("box.prebuild", payload) do
      {:ok, cmd} ->
        {:ok, cmd, Enum.reject([token | registry_tokens(payload)], &is_nil/1)}

      {:error, errors} ->
        {:error, "Couldn't make the build's command: #{inspect(errors)}"}
    end
  end

  defp send_build(box, prebuild, op, cmd) do
    case Agents.dispatch(box.id, cmd) do
      :ok ->
        broadcast(prebuild)
        {:ok, prebuild}

      {:error, :offline} ->
        with {:ok, _op, recorded} <-
               Operations.finish(op.id, "error", %{}, "the box is offline", &record_result/1),
             do: after_result(recorded)

        {:error, "The box is offline."}
    end
  end

  defp token(repo) do
    case GitHub.prebuild_token(repo) do
      {:ok, token} ->
        token

      {:error, :not_configured} ->
        nil

      {:error, reason} ->
        Logger.warning(
          "couldn't get a token for a prebuild of #{repo.full_name}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp limits(repo) do
    [cpus: repo.cpu_limit, memory_mb: repo.memory_limit_mb]
    |> Enum.reject(&is_nil(elem(&1, 1)))
    |> Map.new()
  end

  defp put_registry_auth(payload, %{registry_token: token} = owner) when is_binary(token) do
    Map.put(payload, :registry_auth, [
      %{host: owner.registry_host || "ghcr.io", username: owner.registry_username, token: token}
    ])
  end

  defp put_registry_auth(payload, _owner), do: payload

  defp registry_tokens(payload),
    do: payload |> Map.get(:registry_auth, []) |> Enum.map(& &1.token)

  @doc """
  Records a box's result for a prebuild operation, in the transaction that
  finishes it (see `Foreman.Operations.finish/5`). A ready prebuild
  replaces the ones before it for the same repo, box, branch and config.

  Nothing leaves for the box or the repo's page until that transaction has
  committed: this returns what `after_result/1` sends then, or nil. A
  delete sent from inside it could reach the box before its operation is
  there to take the result, and one for a result that's rolled back would
  take a disk the control plane still has as ready.
  """
  def record_result(%Operation{action: "box.prebuild"} = op) do
    case Repo.one(from p in Prebuild, where: p.op_id == ^op.id) do
      nil -> forgotten(op)
      prebuild -> record(prebuild, op)
    end
  end

  def record_result(_op), do: nil

  @doc "Sends what `record_result/1` left for after its transaction committed."
  def after_result({:prebuilds, changed, deletes}) do
    for {box_id, cmd} <- deletes, do: Agents.dispatch(box_id, cmd)
    Enum.each(changed, &broadcast/1)
    :ok
  end

  def after_result(nil), do: :ok

  defp record(prebuild, %{status: "succeeded"} = op) do
    prebuild =
      prebuild
      |> Ecto.Changeset.change(
        status: "ready",
        error: nil,
        size_mb: size(op.result),
        built_at: DateTime.utc_now()
      )
      |> Repo.update!()

    replaced =
      Repo.all(
        from p in Prebuild,
          where:
            p.repo_id == ^prebuild.repo_id and p.box_id == ^prebuild.box_id and
              p.branch == ^prebuild.branch and p.config_path == ^prebuild.config_path and
              p.status != "building" and p.id != ^prebuild.id
      )

    {:prebuilds, [prebuild | replaced], Enum.map(replaced, &forget(&1, op.user_id))}
  end

  defp record(prebuild, op) do
    prebuild =
      prebuild
      |> Ecto.Changeset.change(status: "failed", error: op.error || "the build failed")
      |> Repo.update!()

    {:prebuilds, [prebuild], []}
  end

  # A build that finished after its prebuild was forgotten (deleted, or
  # replaced after it had been given up on): the disk it made is no one's.
  defp forgotten(%{status: "succeeded", args: %{"prebuild_id" => id}} = op) when is_binary(id),
    do: {:prebuilds, [], [delete_command(op.box_id, id, op.user_id)]}

  defp forgotten(_op), do: nil

  defp size(%{"size_mb" => mb}) when is_integer(mb) and mb >= 0, do: mb
  defp size(_result), do: nil

  @doc """
  Called as a box's agent joins: fails the builds it was sent and doesn't
  have (`in_flight` is what it still has queued or running), lost in a
  restart, rather than leave them building, and holding up the next
  build, until Housekeeping gives up on them hours later. A result that
  turns up after all (a build that finished while the box was away, from
  the agent's outbox) still counts.
  """
  def fail_lost(box_id, in_flight) do
    from(o in Operation,
      where:
        o.box_id == ^box_id and o.action == "box.prebuild" and
          o.status in ["dispatched", "running"] and o.id not in ^in_flight
    )
    |> Repo.all()
    |> Enum.each(fn op ->
      with {:ok, _op, recorded} <-
             Operations.timed_out(
               op,
               "the box's agent restarted during the build",
               &record_result/1
             ),
           do: after_result(recorded)
    end)
  end

  @doc "Takes a prebuild off its box, and forgets it."
  def delete(%Scope{} = scope, %Prebuild{} = prebuild) do
    cond do
      not Scope.admin?(scope) ->
        {:error, :unauthorized}

      prebuild.status == "building" ->
        {:error, "It's still building; delete it once it's done."}

      not Boxes.online?(prebuild.box_id) ->
        {:error, "The box is offline."}

      true ->
        {:ok, delete} = Repo.transact(fn -> {:ok, forget(prebuild, Scope.user_id(scope))} end)
        after_result({:prebuilds, [prebuild], [delete]})
    end
  end

  # The record goes now, and the box is told to delete its copy once that's
  # committed. A box that misses the delete keeps the disk until it's next
  # pruned, which deletes every prebuild the control plane doesn't name
  # (`Foreman.Agents.run_box_command/3`); nothing starts from a prebuild the
  # control plane doesn't name.
  defp forget(prebuild, user_id) do
    Repo.delete!(prebuild)
    delete_command(prebuild.box_id, prebuild.id, user_id)
  end

  defp delete_command(box_id, prebuild_id, user_id) do
    {:ok, cmd} = Command.new("box.prebuild.delete", %{prebuild_id: prebuild_id})

    Operations.create!(%{
      id: cmd.op_id,
      box_id: box_id,
      user_id: user_id,
      action: "box.prebuild.delete",
      command: "box.prebuild.delete",
      args: %{"prebuild_id" => prebuild_id},
      status: "dispatched",
      dispatched_at: DateTime.utc_now()
    })

    {box_id, cmd}
  end

  defp config_path(repo), do: repo.devcontainer_path || @default_config
end
