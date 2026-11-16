defmodule Foreman.Prebuilds do
  @moduledoc """
  Prebuilds (`Foreman.Prebuilds.Prebuild`): an admin has a box build one
  for a repo's default branch and devcontainer config, and new
  environments of the repo on that box, on that branch, start from it
  instead of cloning and building from nothing. Another build replaces it
  once it's ready.

  A prebuild belongs to no one: it clones with an installation token that
  reads the repo and nothing else, and has no one's secrets.
  """
  import Ecto.Query

  alias Foreman.{Agents, Boxes, GitHub, Operations, Repo, Scope, Tailscale}
  alias Foreman.Operations.Redactions
  alias Foreman.Prebuilds.Prebuild
  alias ForemanProtocol.Command

  require Logger

  @default_config ".devcontainer/devcontainer.json"

  def subscribe(repo_id), do: Phoenix.PubSub.subscribe(Foreman.PubSub, topic(repo_id))

  defp topic(repo_id), do: "prebuilds:#{repo_id}"

  defp broadcast(%Prebuild{} = prebuild) do
    Phoenix.PubSub.broadcast(Foreman.PubSub, topic(prebuild.repo_id), {:prebuild, prebuild.id})
  end

  @doc "The latest prebuild of a repo on each box, by box id."
  def latest_by_box(repo) do
    from(p in Prebuild, where: p.repo_id == ^repo.id, order_by: [asc: p.inserted_at])
    |> Repo.all()
    |> Map.new(&{&1.box_id, &1})
  end

  @doc "One of a repo's prebuilds."
  def get(repo, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from p in Prebuild, where: p.id == ^id and p.repo_id == ^repo.id)
      :error -> nil
    end
  end

  @doc "The id of the ready prebuild a new environment of `repo` on a box and branch starts from."
  def ready_id(repo, box_id, branch) do
    config_path = config_path(repo)

    Repo.one(
      from p in Prebuild,
        where:
          p.repo_id == ^repo.id and p.box_id == ^box_id and p.branch == ^branch and
            p.config_path == ^config_path and p.status == "ready",
        order_by: [desc: p.built_at],
        limit: 1,
        select: p.id
    )
  end

  @doc """
  Has `box` build a prebuild of `repo`'s default branch. The prebuild is
  `building` until the box reports back (`record_result/1`).
  """
  def build(%Scope{} = scope, repo, box) do
    box = Boxes.get_box(box.id) || box

    with :ok <- check_build(scope, repo, box) do
      prebuild =
        Repo.insert!(%Prebuild{
          repo_id: repo.id,
          box_id: box.id,
          branch: repo.default_branch,
          config_path: config_path(repo)
        })

      send_build(scope, repo, box, prebuild)
    end
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

  defp send_build(scope, repo, box, prebuild) do
    repo = Repo.preload(repo, :owner)
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
        tailscale: %{enabled: Tailscale.configured?()}
      }
      |> put_registry_auth(repo.owner)

    {:ok, cmd} = Command.new("box.prebuild", payload)
    Redactions.put_values(cmd.op_id, Enum.reject([token | registry_tokens(payload)], &is_nil/1))

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

    prebuild = prebuild |> Ecto.Changeset.change(op_id: op.id) |> Repo.update!()

    case Agents.dispatch(box.id, cmd) do
      :ok ->
        broadcast(prebuild)
        {:ok, prebuild}

      {:error, :offline} ->
        Operations.finish(op.id, "error", %{}, "the box is offline", &record_result/1)
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
  """
  def record_result(%Operations.Operation{action: "box.prebuild"} = op) do
    case Repo.one(from p in Prebuild, where: p.op_id == ^op.id) do
      nil -> nil
      prebuild -> record(prebuild, op)
    end
  end

  def record_result(_op), do: nil

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

    Repo.all(
      from p in Prebuild,
        where:
          p.repo_id == ^prebuild.repo_id and p.box_id == ^prebuild.box_id and
            p.branch == ^prebuild.branch and p.config_path == ^prebuild.config_path and
            p.status != "building" and p.id != ^prebuild.id
    )
    |> Enum.each(&remove(&1, op.user_id))

    broadcast(prebuild)
    prebuild
  end

  defp record(prebuild, op) do
    prebuild =
      prebuild
      |> Ecto.Changeset.change(status: "failed", error: op.error || "the build failed")
      |> Repo.update!()

    broadcast(prebuild)
    prebuild
  end

  defp size(%{"size_mb" => mb}) when is_integer(mb) and mb >= 0, do: mb
  defp size(_result), do: nil

  @doc "Takes a prebuild off its box, and forgets it."
  def delete(%Scope{} = scope, %Prebuild{} = prebuild) do
    cond do
      not Scope.admin?(scope) -> {:error, :unauthorized}
      not Boxes.online?(prebuild.box_id) -> {:error, "The box is offline."}
      true -> remove(prebuild, Scope.user_id(scope))
    end
  end

  # The box deletes its copy; the record goes now. A box that drops the
  # delete keeps the disk until someone deletes it again by hand, which
  # costs space, never correctness: nothing starts from a prebuild the
  # control plane doesn't name.
  defp remove(prebuild, user_id) do
    {:ok, cmd} = Command.new("box.prebuild.delete", %{prebuild_id: prebuild.id})

    Operations.create!(%{
      id: cmd.op_id,
      box_id: prebuild.box_id,
      user_id: user_id,
      action: "box.prebuild.delete",
      command: "box.prebuild.delete",
      args: %{"prebuild_id" => prebuild.id},
      status: "dispatched",
      dispatched_at: DateTime.utc_now()
    })

    _ = Agents.dispatch(prebuild.box_id, cmd)
    Repo.delete!(prebuild)
    broadcast(prebuild)
    :ok
  end

  defp config_path(repo), do: repo.devcontainer_path || @default_config
end
