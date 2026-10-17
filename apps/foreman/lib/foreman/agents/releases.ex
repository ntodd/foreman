defmodule Foreman.Agents.Releases do
  @moduledoc """
  Agent releases the control plane serves for self-update.

  CI builds and signs each release (the signing key never touches the
  control plane). The control plane image carries the agents built with
  it and registers them at boot; an admin can register others by hand.
  When a box's desired agent version differs from what it runs, the box
  gets an `agent.update` command on its next connect.
  """
  import Ecto.Query

  require Logger

  alias Foreman.Agents.Release
  alias Foreman.Boxes.Box
  alias Foreman.Operations.Operation
  alias Foreman.{Operations, Repo}
  alias ForemanProtocol.{Auth, Command}

  def list, do: Release |> order_by(desc: :inserted_at) |> Repo.all()

  def get(version, target), do: Repo.get_by(Release, version: version, target: target)

  @doc """
  The release a new box installs: the target's highest version, passing
  over prereleases unless there's nothing else.
  """
  def latest(target) do
    # A release whose tarball is gone (kept in a temp dir that a recreate
    # cleared) never counts.
    releases =
      Repo.all(from r in Release, where: r.target == ^target)
      |> Enum.filter(&File.regular?(&1.path))

    case releases |> Enum.map(& &1.version) |> highest() do
      nil -> nil
      version -> Enum.find(releases, &(&1.version == version))
    end
  end

  @doc """
  The newest agent this control plane's image carries for the target,
  once it's registered. Boxes that aren't pinned to a version follow it.
  """
  def bundled_version(target) do
    registered =
      for release <- Repo.all(from r in Release, where: r.target == ^target),
          File.regular?(release.path),
          do: release.version

    for {_file, version, ^target} <- bundled_files(bundled_dir()), version in registered do
      version
    end
    |> highest()
  end

  @doc """
  The version a box should run: the one it's pinned to, or else the
  newest agent the control plane carries for its architecture. Nil when
  neither applies, which leaves the box on what it runs.
  """
  def target_version(%Box{desired_agent_version: pinned}) when is_binary(pinned), do: pinned
  def target_version(%Box{arch: arch}) when is_binary(arch), do: fleet_version(arch)
  def target_version(%Box{}), do: nil

  @doc """
  The agent version this control plane gives boxes for the target: the
  newest its image carries, or, for an image that carries none for the
  target (one built by hand), the newest registered. New boxes install
  it, and boxes that aren't pinned follow it, so the two always agree.

  Nil while the image's own agents aren't registered (at boot, or when
  registration fails), so boxes stay where they are rather than follow
  some other release.
  """
  def fleet_version(target) do
    cond do
      Enum.any?(bundled_files(bundled_dir()), &match?({_, _, ^target}, &1)) ->
        bundled_version(target)

      release = latest(target) ->
        release.version

      true ->
        nil
    end
  end

  # The highest version, passing over prereleases unless there's nothing
  # else. register/4's pattern lets through a few strings Version can't
  # parse ("01.2.3"); those never count.
  defp highest(versions) do
    {pre, stable} =
      for version <- versions, {:ok, parsed} <- [Version.parse(version)] do
        {parsed, version}
      end
      |> Enum.split_with(fn {parsed, _} -> parsed.pre != [] end)

    case Enum.max_by(if(stable == [], do: pre, else: stable), &elem(&1, 0), Version, fn -> nil end) do
      {_, version} -> version
      nil -> nil
    end
  end

  def storage_dir do
    # runtime.exs passes FOREMAN_AGENT_RELEASE_DIR through as nil when
    # it's unset, and an env file can set it to "".
    case Application.get_env(:foreman, :agent_release_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(System.tmp_dir!(), "foreman-agent-releases")
    end
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

  defp do_register(version, target, tarball_path, signature) do
    with {:ok, sha} <- sha256(tarball_path),
         {:ok, key} <- public_key(),
         :ok <- Auth.verify_release(version, target, sha, signature, key) do
      case get(version, target) do
        # The same tarball again (the image registers its agents on every
        # boot): nothing to change, as long as the stored copy is intact.
        %Release{sha256: ^sha, signature: ^signature} = release ->
          if sha256(release.path) == {:ok, sha},
            do: {:ok, release},
            else: store(version, target, tarball_path, sha, signature)

        _ ->
          store(version, target, tarball_path, sha, signature)
      end
    else
      {:error, :bad_signature} -> {:error, "the signature doesn't verify against the release key"}
      error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sha256(path) do
    {:ok,
     path
     |> File.stream!(65_536)
     |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
     |> :crypto.hash_final()
     |> Base.encode16(case: :lower)}
  rescue
    e in File.Error -> {:error, Exception.message(e)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp store(version, target, tarball_path, sha, signature) do
    dest = Path.join(storage_dir(), "foreman_agent-#{version}-#{target}.tar.gz")
    File.mkdir_p!(storage_dir())
    # Copied beside it and renamed into place, so a box downloading it
    # never gets half a file, and a copy cut short never replaces one.
    partial = "#{dest}.partial-#{System.unique_integer([:positive])}"
    File.cp!(tarball_path, partial)
    File.rename!(partial, dest)

    %Release{
      version: version,
      target: target,
      sha256: sha,
      signature: signature,
      size: File.stat!(dest).size,
      path: dest
    }
    |> Repo.insert(
      on_conflict: {:replace, [:sha256, :signature, :size, :path]},
      conflict_target: [:version, :target],
      returning: true
    )
  end

  @bundled ~r/\Aforeman_agent-(.+)-((?:linux|darwin)-(?:amd64|arm64))\.tar\.gz\z/

  @doc """
  Registers the agent releases the control plane image carries
  (`foreman_agent-<version>-<target>.tar.gz`, each with a `.sig` beside
  it), so a control plane always serves the agents built with it. Called
  at boot; releases already registered are left as they are, and so are
  ones that aren't in the bundle. With no argument, logs what it couldn't
  register.
  """
  def register_bundled do
    for {file, result} <- register_bundled(bundled_dir()) do
      case {Regex.run(@bundled, file), result} do
        {[_, version, target], {:ok, _}} ->
          Logger.info("bundled agent #{version} for #{target} is registered")

        {[_, version, target], {:error, reason}} ->
          Logger.warning("bundled agent #{version} for #{target} wasn't registered: #{reason}")
      end
    end
  end

  @doc """
  Started by the application supervisor after migrations and before the
  endpoint, so a box installing right after boot already gets this
  image's agents. Registers, then returns `:ignore`; a failure is logged
  and doesn't stop the control plane from starting.
  """
  def start_registering_bundled do
    register_bundled()
    :ignore
  rescue
    e ->
      Logger.error("couldn't register the bundled agents: #{Exception.message(e)}")
      :ignore
  end

  def register_bundled(dir) do
    for {file, version, target} <- bundled_files(dir) do
      {file, register_file(Path.join(dir, file), version, target)}
    end
  end

  defp bundled_dir do
    Application.get_env(
      :foreman,
      :bundled_agent_dir,
      Application.app_dir(:foreman, "priv/agent/releases")
    )
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The directory is the image's own (or the operator's); names are
  # matched against @bundled, and register/4 checks them again.
  defp bundled_files(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        for file <- Enum.sort(files), [_, version, target] <- [Regex.run(@bundled, file)] do
          {file, version, target}
        end

      {:error, _} ->
        []
    end
  end

  defp bundled_files(nil), do: []

  # sobelow_skip ["Traversal.FileModule"]
  # One entry that can't be registered (unreadable, or a storage dir that
  # can't be written) is reported, and the rest are still tried.
  defp register_file(tarball, version, target) do
    case File.read(tarball <> ".sig") do
      {:ok, signature} -> register(version, target, tarball, String.trim(signature))
      {:error, _} -> {:error, "no signature (#{Path.basename(tarball)}.sig)"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp public_key do
    with key when is_binary(key) and key != "" <-
           Application.get_env(:foreman, :agent_release_public_key),
         {:ok, key} <- key |> String.trim() |> Base.decode64() do
      {:ok, key}
    else
      :error ->
        {:error, "the agent release key (FOREMAN_AGENT_RELEASE_PUBLIC_KEY) isn't valid base64"}

      _ ->
        {:error, "no agent release key configured (FOREMAN_AGENT_RELEASE_PUBLIC_KEY)"}
    end
  end

  # How long an agent has to come back on the version it was sent before
  # the update counts as failed (a crash loop and a systemd rollback take
  # a few minutes). Once it has reported the new release in place, it
  # restarts only when it's idle, which it waits up to an hour for.
  @update_grace_seconds 600
  @restart_grace_seconds 70 * 60

  @doc """
  Sends agent.update to a box whose target version (see
  `target_version/1`) differs from what it runs. Not while an update is
  still under way, not while the box's environments have operations
  running (the agent restarts), and not for a version that already failed
  on this box.
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
    with version when is_binary(version) <- target_version(box),
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

          # A version that failed earlier is behind the box now.
          if box.failed_agent_version in [nil, version],
            do: box,
            else: box |> Ecto.Changeset.change(failed_agent_version: nil) |> Repo.update!()

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
  failed twice in a row there, it isn't sent again until an admin
  retries it or picks another version; one failure might be bad luck (a
  download cut short, the network down while the new release started).
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
      [{"failed", %{"version" => ^version} = a}, {"failed", %{"version" => ^version} = b}]
      when not is_map_key(a, "retried") and not is_map_key(b, "retried") ->
        true

      _ ->
        false
    end
  end

  @doc """
  Sets aside the box's failed updates, so a version an admin retries gets
  its two tries again.
  """
  def forget_failures(%Box{} = box) do
    from(o in Operation,
      where: o.box_id == ^box.id and o.action == "agent.update" and o.status == "failed"
    )
    |> Repo.all()
    |> Enum.each(fn op ->
      op
      |> Ecto.Changeset.change(args: Map.put(op.args || %{}, "retried", true))
      |> Repo.update!()
    end)
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
