defmodule Foreman.Agents.Releases do
  @moduledoc """
  Agent releases the control plane serves for self-update.

  CI builds and signs each release (the signing key never touches the
  control plane) and an admin registers the tarball here. When a box's
  desired agent version differs from what it runs, the box gets an
  `agent.update` command on its next connect.
  """
  import Ecto.Query

  alias Foreman.Agents.Release
  alias Foreman.Boxes.Box
  alias Foreman.Operations.Operation
  alias Foreman.{Operations, Repo}
  alias ForemanProtocol.{Auth, Command}

  def list, do: Release |> order_by(desc: :inserted_at) |> Repo.all()

  def get(version, target), do: Repo.get_by(Release, version: version, target: target)

  def storage_dir do
    Application.get_env(
      :foreman,
      :agent_release_dir,
      Path.join(System.tmp_dir!(), "foreman-agent-releases")
    )
  end

  @doc """
  Registers a release tarball. The signature must verify against the
  configured release public key, so the control plane can't be used to
  hand out a build CI didn't sign.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # version and target are checked against strict patterns before they
  # reach a path; tarball_path is the admin's own upload.
  def register(version, target, tarball_path, signature) do
    with :ok <-
           check_name(version, ~r/\A\d{1,4}\.\d{1,4}\.\d{1,4}(-[0-9A-Za-z.]{1,32})?\z/, "version"),
         :ok <- check_name(target, ~r/\A(linux|darwin)-(amd64|arm64)\z/, "target") do
      do_register(version, target, tarball_path, signature)
    end
  end

  defp check_name(value, pattern, label) do
    if is_binary(value) and Regex.match?(pattern, value),
      do: :ok,
      else: {:error, "invalid #{label}"}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp do_register(version, target, tarball_path, signature) do
    sha =
      tarball_path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    with {:ok, key} <- public_key(),
         :ok <- Auth.verify_release(version, target, sha, signature, key) do
      dest = Path.join(storage_dir(), "foreman_agent-#{version}-#{target}.tar.gz")
      File.mkdir_p!(storage_dir())
      File.cp!(tarball_path, dest)

      %Release{
        version: version,
        target: target,
        sha256: sha,
        signature: signature,
        size: File.stat!(dest).size,
        path: dest
      }
      |> Repo.insert(on_conflict: :replace_all, conflict_target: [:version, :target])
    else
      {:error, :bad_signature} -> {:error, "the signature doesn't verify against the release key"}
      error -> error
    end
  end

  defp public_key do
    case Application.get_env(:foreman, :agent_release_public_key) do
      key when is_binary(key) and key != "" -> {:ok, Base.decode64!(key)}
      _ -> {:error, "no agent release key configured (FOREMAN_AGENT_RELEASE_PUBLIC_KEY)"}
    end
  end

  # How long an agent has to come back on the version it was sent before
  # the update counts as failed (a crash loop and a systemd rollback take
  # a few minutes). Once it has reported the new release in place, it
  # restarts only when it's idle, which it waits up to an hour for.
  @update_grace_seconds 600
  @restart_grace_seconds 70 * 60

  @doc """
  Sends agent.update to a box whose desired version differs from what it
  runs. Not while an update is still under way, not while the box's
  environments have operations running (the agent restarts), and not for
  a version that already failed on this box.
  """
  def maybe_update(%Box{} = box) do
    # The Dispatch cron and an agent joining can both get here at once;
    # each would see no update in flight and send one.
    :global.trans({{__MODULE__, :update, box.id}, self()}, fn ->
      box |> fresh() |> settle_updates() |> send_update()
    end)
  end

  defp fresh(box), do: Foreman.Repo.reload(box) || box

  defp send_update(box) do
    with version when is_binary(version) <- box.desired_agent_version,
         true <- version != box.agent_version,
         true <- version != box.failed_agent_version,
         false <- updating?(box),
         false <- busy?(box),
         target when is_binary(target) <- box.arch,
         %Release{} = release <- get(version, target) do
      url = "#{Foreman.Config.base_url()}/agent/releases/#{version}/#{target}"

      {:ok, cmd} =
        Command.new("agent.update", %{
          version: version,
          url: url,
          sha256: release.sha256,
          signature: release.signature
        })

      Operations.create!(%{
        id: cmd.op_id,
        box_id: box.id,
        action: "agent.update",
        command: "agent.update",
        status: "dispatched",
        dispatched_at: DateTime.utc_now(),
        args: %{"version" => version}
      })

      Foreman.Agents.dispatch(box.id, cmd)
    else
      _ -> :ok
    end
  end

  @doc """
  Settles the box's unfinished updates against the version its agent
  runs: done if it's on the new version, failed if it hasn't got there
  within the grace period. A version that fails twice in a row is
  remembered so it isn't sent again. Returns the box.
  """
  def settle_updates(%Box{} = box) do
    Enum.reduce(active_updates(box), box, fn op, box ->
      version = (op.args || %{})["version"]

      cond do
        version == box.agent_version ->
          Operations.mark(op, "succeeded",
            result: Map.merge(op.result || %{}, %{"version" => version}),
            finished_at: DateTime.utc_now()
          )

          box

        overdue?(op) ->
          op =
            Operations.mark(op, "failed",
              error:
                "the agent didn't come back on #{version}; it's still on #{box.agent_version}",
              finished_at: DateTime.utc_now()
            )

          update_failed(op, box)

        true ->
          box
      end
    end)
  end

  defp overdue?(op) do
    {since, grace} =
      case (op.args || %{})["restart_reported_at"] do
        at when is_binary(at) ->
          {:ok, at, _} = DateTime.from_iso8601(at)
          {at, @restart_grace_seconds}

        _ ->
          {op.dispatched_at || op.inserted_at, @update_grace_seconds}
      end

    DateTime.diff(DateTime.utc_now(), since) > grace
  end

  @doc """
  Records an update that failed on its box. Once the same version has
  failed twice in a row there, it isn't sent again until an admin picks a
  version again; one failure might be bad luck (a download cut short,
  the network down while the new release started).
  """
  def update_failed(%Operation{action: "agent.update", box_id: box_id} = op, box \\ nil) do
    box = box || Repo.get!(Box, box_id)

    with version when is_binary(version) <- (op.args || %{})["version"],
         true <- failed_twice?(box, version) do
      box |> Ecto.Changeset.change(failed_agent_version: version) |> Repo.update!()
    else
      _ -> box
    end
  end

  defp failed_twice?(box, version) do
    from(o in Operation,
      where:
        o.box_id == ^box.id and o.action == "agent.update" and
          o.status in ["succeeded", "failed"],
      order_by: [desc: o.inserted_at],
      limit: 2,
      select: {o.status, o.args}
    )
    |> Repo.all()
    |> case do
      [{"failed", %{"version" => ^version}}, {"failed", %{"version" => ^version}}] -> true
      _ -> false
    end
  end

  defp active_updates(box) do
    Repo.all(
      from o in Operation,
        where:
          o.box_id == ^box.id and o.action == "agent.update" and
            o.status in ["dispatched", "running"],
        order_by: o.inserted_at
    )
  end

  defp updating?(box), do: active_updates(box) != []

  defp busy?(box) do
    Repo.exists?(
      from o in Operation,
        where:
          o.box_id == ^box.id and not is_nil(o.environment_id) and
            o.status in ["dispatched", "running"]
    )
  end
end
