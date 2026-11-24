defmodule ForemanAgent.VM.Env do
  @moduledoc """
  Environment commands on a box: each environment runs in a VM of its
  own, and the agent in it does the work (`ForemanAgent.Env`, in guest
  mode). The box's agent makes and boots the VM, relays the command
  through `ForemanAgent.VM.Link` with its op id, and passes the guest's
  logs and result on. A command resent after a reconnect, here or in the
  guest, runs once.

  Secrets: the box keeps each environment's latest files on its own
  tmpfs (`secrets_root`), readable by the agent alone, as it always has,
  and writes them into the guest after every boot. A secrets write for a
  stopped environment succeeds, so the control plane's order after a
  reboot (secrets, then start) works as it did.

  Stop shuts the guest down after the environment's own stop (so
  sidecars get theirs), and destroy throws the VM's disks away. Suspend
  writes the VM's memory to disk and stops it; whatever needs the VM next
  (a start, usually) resumes it from there, and the snapshot, which holds
  whatever was in the guest's memory (secrets included), is deleted once
  the VM is back.
  """

  alias ForemanAgent.{Env, VM}
  alias ForemanAgent.VM.{Image, Link, Links, Machine, Prebuild}
  alias ForemanProtocol.{Command, Schema}

  require Logger

  defmodule SnapshotSyncError do
    defexception [:message]
  end

  # How long a guest gets to shut down before the VM is stopped.
  @power_off_timeout 60_000

  @spec run(Command.t(), (String.t(), String.t() -> any()), map()) ::
          {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def run(cmd, log, ctx) do
    with :ok <- ready_for_command(cmd, ctx.config), do: execute(cmd, log, ctx)
  rescue
    e in SnapshotSyncError -> {:error, Exception.message(e)}
  end

  defp ready_for_command(%Command{type: type}, config)
       when type in ["env.create", "env.rebuild", "env.start"],
       do: Machine.impl(config).ready(config)

  defp ready_for_command(%Command{type: "env.stop", payload: p}, config) do
    if VM.suspended?(config, p.env_id), do: Machine.impl(config).ready(config), else: :ok
  end

  defp ready_for_command(_cmd, _config), do: :ok

  defp execute(%Command{type: type, payload: p} = cmd, log, ctx)
       when type in ["env.create", "env.rebuild"] do
    with :ok <- Env.check_clone_url(p.clone_url, ctx.config),
         {:ok, _} <- cache_secrets(ctx, p.env_id, p.files),
         {:ok, spec} <- prepare(p, ctx, log, type),
         {:ok, _how} <- ensure_running(p.env_id, spec, ctx, log),
         :ok <- push_secrets(p.env_id, log, ctx) do
      relay(cmd, log, ctx)
    end
  end

  # A start that resumed the VM says so: the environment's processes kept
  # the secrets they had when it was suspended.
  defp execute(%Command{type: "env.start", payload: p} = cmd, log, ctx) do
    with {:ok, meta} <- existing(ctx.config, p.env_id),
         {:ok, p} <- start_payload(p, meta),
         {:ok, spec} <- prepare(p, ctx, log, "env.start"),
         {:ok, how} <- ensure_running(p.env_id, spec, ctx, log, cmd.op_id),
         {:ok, meta} <- VM.read_meta(ctx.config, p.env_id),
         resumed? = how == :resumed or (how == :running and meta["resumed_by"] == cmd.op_id),
         :ok <- push_secrets(p.env_id, log, ctx) do
      case relay(cmd, log, ctx) do
        {:ok, result} when resumed? -> {:ok, Map.put(result, "resumed", true)}
        other -> other
      end
    end
  end

  defp execute(%Command{type: "env.suspend", payload: p}, log, ctx) do
    machine = Machine.impl(ctx.config)
    paths = VM.paths(ctx.config, p.env_id)

    cond do
      machine.running?(p.env_id, ctx.config) ->
        log.("info", "Saving the environment's VM to disk\n")
        tmp = paths.snapshot <> ".tmp"
        VM.remove_tree!(tmp)
        :ok = VM.mkdir_private(tmp)

        case machine.snapshot(p.env_id, tmp, ctx.config) do
          :ok ->
            Links.stop(p.env_id)
            # On disk before it counts: a power cut after this mustn't
            # leave a torn snapshot that looks whole.
            sync_path!(tmp, ctx.runner)
            discard_snapshot(ctx.config, p.env_id, ctx.runner)
            File.rename!(tmp, paths.snapshot)
            sync_path!(paths.dir, ctx.runner)
            suspend_result(ctx.config, p.env_id)

          {:error, message} ->
            VM.remove_tree(tmp)
            {:error, message}
        end

      VM.suspended?(ctx.config, p.env_id) ->
        sync_path!(paths.dir, ctx.runner)
        suspend_result(ctx.config, p.env_id)

      true ->
        {:error, "the environment isn't running"}
    end
  end

  defp execute(%Command{type: "env.stop", payload: p} = cmd, log, ctx) do
    machine = Machine.impl(ctx.config)

    resume_result =
      if VM.suspended?(ctx.config, p.env_id), do: resume_to_stop(p, log, ctx), else: :ok

    with :ok <- resume_result do
      if machine.running?(p.env_id, ctx.config),
        do: stop_running(cmd, machine, log, ctx),
        else: {:ok, %{}}
    end
  end

  defp execute(%Command{type: "env.secrets.write", payload: p} = cmd, log, ctx) do
    with {:ok, result} <- cache_secrets(ctx, p.env_id, p.files, Map.get(p, :keep, [])) do
      if Machine.impl(ctx.config).running?(p.env_id, ctx.config),
        do: relay(cmd, log, ctx),
        else: {:ok, result}
    end
  end

  defp execute(%Command{type: "env.destroy", payload: p}, log, ctx) do
    machine = Machine.impl(ctx.config)
    log.("info", "Removing the environment's VM\n")
    Links.stop(p.env_id)

    with :ok <- machine.release(p.env_id, ctx.config),
         :ok <- VM.remove_tree(Path.join(ctx.config.secrets_root, p.env_id)),
         :ok <- VM.remove_tree(VM.paths(ctx.config, p.env_id).dir),
         :ok <- VM.remove_tree(VM.paths(ctx.config, p.env_id).meta) do
      {:ok, %{}}
    end
  end

  # restart, logs, git_status and connect need the environment running.
  # A restart brings the containers up again, so the secrets go first.
  defp execute(%Command{type: type, payload: p} = cmd, log, ctx) do
    cond do
      not Machine.impl(ctx.config).running?(p.env_id, ctx.config) ->
        {:error, "the environment isn't running"}

      type == "env.restart" ->
        with :ok <- push_secrets(p.env_id, log, ctx), do: relay(cmd, log, ctx)

      true ->
        relay(cmd, log, ctx)
    end
  end

  # A suspended environment comes back first, so its own stop runs. One
  # that can't is stopped all the same: what was saved is thrown away.
  defp resume_to_stop(p, log, ctx) do
    with {:ok, meta} <- existing(ctx.config, p.env_id),
         {:ok, p} <- start_payload(p, meta) do
      resume_or_discard(p, log, ctx)
    end
  end

  defp resume_or_discard(p, log, ctx) do
    case resume(p, log, ctx) do
      :ok ->
        :ok

      {:error, message} ->
        log.(
          "info",
          "Couldn't resume the environment to stop it (#{message}); discarding what was saved\n"
        )

        discard_snapshot(ctx.config, p.env_id, ctx.runner)
    end
  end

  # A guest that never finishes its part doesn't keep the VM up: it's shut
  # down either way, which stops the environment as surely.
  defp stop_running(%Command{payload: p} = cmd, machine, log, ctx) do
    result =
      case relay(cmd, log, ctx, timeout: ctx.config.vm_relay_stop_timeout) do
        {:ok, _} = ok ->
          ok

        error ->
          log.("info", "The environment's own stop didn't finish (#{error_text(error)})\n")
          {:ok, %{}}
      end

    log.("info", "Shutting the environment's VM down\n")

    case machine.power_off(p.env_id, @power_off_timeout, ctx.config) do
      :ok ->
        Links.stop(p.env_id)
        result

      # It didn't shut down in time and was stopped: said so, for a
      # prebuild, whose disk isn't kept from a guest stopped mid-write.
      :killed ->
        Links.stop(p.env_id)
        with {:ok, map} <- result, do: {:ok, Map.put(map, "forced_off", true)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp resume(p, log, ctx) do
    with {:ok, spec} <- prepare(p, ctx, log, "env.start"),
         {:ok, _how} <- ensure_running(p.env_id, spec, ctx, log),
         do: :ok
  end

  @doc """
  Run as the agent starts, before any operation: what a suspend that was
  cut short left. A half-written snapshot goes, a VM left paused carries
  on, and a snapshot beside a VM that's running (it was resumed, and the
  agent stopped before deleting it) goes too: restoring it later would
  put old memory over a disk that has changed since.
  """
  @spec recover(ForemanAgent.Config.t()) :: :ok
  def recover(config) do
    machine = Machine.impl(config)

    recover_disk_staging(config)
    recover_provisioning(config)

    # A prebuild being built when the agent stopped: nothing will finish it.
    for id <- VM.list(config, :all),
        match?({:ok, %{"kind" => "prebuild"}}, VM.read_meta(config, id)),
        do: Prebuild.discard(config, id)

    runner = ForemanAgent.Runner.impl()

    for env_id <- VM.list(config) do
      paths = VM.paths(config, env_id)
      VM.remove_tree(paths.snapshot <> ".tmp")
      remove_discarded(paths, runner)

      cond do
        # Left until the guest answers (ensure_running/4): Cloud Hypervisor
        # may still be reading it.
        machine.running?(env_id, config) ->
          _ = machine.unpause(env_id, config)

        # Handed to a VM that has gone since: never restored.
        File.dir?(paths.snapshot) and not VM.suspended?(config, env_id) ->
          discard_snapshot(config, env_id, runner)

        true ->
          :ok
      end
    end

    :ok
  end

  defp recover_disk_staging(config) do
    # This runs once before the control-plane connection can accept work.
    # Only remove the temporary names generated by format_new_disk/copy_disk.
    # A disk already linked into place keeps its published name and contents.
    for path <- Path.wildcard(Path.join(config.vm_root, ".disk-*"), match_dot: true),
        Regex.match?(~r/\A\.disk-[A-Za-z0-9_-]{22}==\z/, Path.basename(path)),
        match?({:ok, %{type: :regular}}, File.lstat(path)) do
      case File.rm(path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("could not remove disk staging file #{path}: #{reason}")
      end
    end
  end

  # Gone in a way an interruption can't undo: renamed aside first (so a
  # half-deleted snapshot can't look whole), then removed.
  defp discard_snapshot(config, env_id, runner) do
    paths = VM.paths(config, env_id)

    if File.exists?(paths.snapshot) do
      aside = paths.snapshot <> ".discard-#{System.unique_integer([:positive])}"
      File.rename!(paths.snapshot, aside)
    end

    remove_discarded(paths, runner)
  end

  defp suspend_result(config, env_id) do
    result = %{"suspended" => true}

    with {:ok, record} <- VM.read_meta(config, env_id),
         %{cpus: cpus, memory_mb: mb} <- VM.resume_size(record, config) do
      {:ok, Map.put(result, "vm_size", %{"cpus" => cpus, "memory_mb" => mb})}
    else
      _ -> {:ok, result}
    end
  end

  defp remove_discarded(paths, runner) do
    case Path.wildcard(paths.snapshot <> ".discard-*") do
      [] ->
        :ok

      leftovers ->
        sync_path!(paths.dir, runner)
        Enum.each(leftovers, &VM.remove_tree!/1)
    end
  end

  # The directory's entries on disk: Erlang can't fsync a directory.
  defp sync_path!(path, runner) do
    case runner.run("sync", ["-f", path], timeout: 60_000) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{status: status}} ->
        raise SnapshotSyncError, "couldn't sync #{path} (status #{status})"

      {:error, reason} ->
        raise SnapshotSyncError, "couldn't sync #{path} (#{inspect(reason)})"
    end
  end

  # Record the operation before handing the snapshot to the hypervisor.
  # A cold boot clears it before starting a new guest process tree.
  defp set_resume_id(config, env_id, op_id) do
    with {:ok, meta} <- VM.read_meta(config, env_id) do
      if meta["resumed_by"] == op_id do
        :ok
      else
        VM.write_meta(config, env_id, Map.put(meta, "resumed_by", op_id))
      end
    end
  end

  # A prebuild's build gives a deadline for everything it relays
  # (`:relay_timeout` in its ctx).
  defp relay(cmd, log, ctx, opts \\ []) do
    opts = Keyword.put_new(opts, :timeout, Map.get(ctx, :relay_timeout, :infinity))
    # The limits size the VM, and nothing in it: Docker in the guest
    # refuses more CPUs than the VM has, which can be fewer than the
    # environment asked for. A running guest can still speak protocol 6,
    # where a start or a stop with limits is refused.
    cmd = %{cmd | payload: Map.delete(cmd.payload, :limits)}

    Link.run(Links.get(cmd.payload.env_id, ctx.config), cmd, log, opts)
  end

  defp error_text({:error, message}) when is_binary(message), do: message
  defp error_text({:error, message, _}) when is_binary(message), do: message
  defp error_text(other), do: inspect(other)

  defp existing(config, env_id) do
    case VM.read_meta(config, env_id) do
      {:ok, meta} ->
        {:ok, meta}

      {:error, :none} ->
        {:error,
         "this environment has no VM on this box (it was made before environment VMs, or its disks are gone); destroy it and create a new one"}
    end
  end

  defp start_payload(%{limits: _} = p, _), do: {:ok, p}

  defp start_payload(_, %{"legacy" => true}),
    do: {:error, "update the control plane to supply limits for this legacy VM"}

  defp start_payload(p, meta), do: {:ok, Map.put(p, :limits, limits(meta))}

  defp limits(%{"cpus" => cpus, "memory_mb" => memory}), do: %{cpus: cpus, memory_mb: memory}
  defp limits(_meta), do: %{}

  # The VM's directory, disks and record. The root disk is made again
  # whenever the guest image changes: the environment keeps nothing there.
  defp prepare(p, ctx, log, type) do
    config = ctx.config
    paths = VM.paths(config, p.env_id)

    with {:ok, guest} <- Image.ensure_guest(config, log),
         {:ok, agent} <- Image.ensure_agent_disk(config, ctx.runner, log),
         :ok <- File.mkdir_p(paths.dir),
         :ok <- File.chmod(paths.dir, 0o700),
         :ok <- ensure_data_disk(paths, p, ctx, log, type, guest.digest),
         p = keep_snapshot_compatible(p, ctx, log),
         {:ok, meta} <- ensure_root_disk(p, paths, guest, ctx, log) do
      size = VM.size(Map.get(p, :limits, %{}), config, VM.box_size(config.proc))

      meta =
        Map.merge(meta, %{
          "cpus" => size.cpus,
          "memory_mb" => size.memory_mb,
          "agent" => agent.version
        })

      VM.write_meta(config, p.env_id, Map.delete(meta, "legacy"))

      {:ok,
       %{
         cpus: size.cpus,
         memory_mb: size.memory_mb,
         guest: guest.digest,
         agent_version: agent.version
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "couldn't prepare the environment's VM: #{inspect(reason)}"}
    end
  end

  # A suspended VM resumes with what it booted with: Cloud Hypervisor
  # restores a snapshot only with the binary, guest image and agent disk it
  # was taken with, and memory the size it was. The box updated since, the
  # snapshot goes and the environment boots afresh.
  defp keep_snapshot_compatible(p, ctx, log) do
    config = ctx.config

    with true <- VM.suspended?(config, p.env_id),
         false <- Machine.impl(config).running?(p.env_id, config),
         {:ok, %{"booted" => booted}} <- VM.read_meta(config, p.env_id) do
      if VM.snapshot_compatible?(booted, config) do
        case booted do
          %{"cpus" => cpus, "memory_mb" => mb} ->
            Map.put(p, :limits, %{cpus: cpus, memory_mb: mb})

          _ ->
            p
        end
      else
        drop_snapshot(p, config, log)
      end
    else
      true -> p
      false -> p
      {:ok, _meta} -> drop_snapshot(p, config, log)
      {:error, _} -> p
    end
  end

  defp drop_snapshot(p, config, log) do
    log.("info", "The box was updated since the environment was suspended; starting it afresh\n")
    discard_snapshot(config, p.env_id, ForemanAgent.Runner.impl())
    p
  end

  # A new environment's disk: a copy of its prebuild's when the box has
  # it, otherwise a fresh sparse ext4 filesystem.
  defp ensure_data_disk(paths, p, ctx, log, type, guest) do
    case File.lstat(paths.data) do
      {:ok, %{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        if type == "env.create" and new_disk?(paths, p, ctx.config),
          do: create_data_disk(paths, p, ctx, log, guest),
          else: {:error, "the existing VM's data disk is missing; restore it before starting"}

      _ ->
        {:error, "the VM's data disk is inaccessible or is not a regular file"}
    end
  end

  defp new_disk?(paths, p, config) do
    # Prebuild.build records its operation before creating the temporary VM.
    # A prepared VM also has a root disk or a legacy record.
    File.lstat(paths.root) == {:error, :enoent} and
      File.lstat(paths.legacy_meta) == {:error, :enoent} and
      (File.lstat(paths.meta) == {:error, :enoent} or
         (p[:prebuild] == true and
            match?({:ok, %{"kind" => "prebuild"}}, VM.read_meta(config, p.env_id))))
  end

  defp create_data_disk(paths, p, ctx, log, guest) do
    prebuild = Map.get(p, :prebuild_id)

    if is_binary(prebuild) and Prebuild.exists?(ctx.config, prebuild) do
      log.("info", "Starting from a prebuild\n")
      adopt_copy(paths, p, ctx, guest, prebuild)
    else
      if is_binary(prebuild),
        do: log.("info", "This box no longer has the prebuild; starting from scratch\n")

      format_new_disk(paths.data, p.env_id, ctx)
    end
  end

  defp adopt_copy(paths, p, ctx, guest, prebuild) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    stage = Path.join(ctx.config.vm_root, ".adopt-" <> nonce)
    clone = Path.join(stage, "data.raw")

    # Only an unpublished copy is attached for cleanup. The destination
    # must still be absent when the fully initialized disk is published.
    with :ok <- File.mkdir(stage) do
      try do
        with :ok <- copy_disk(Prebuild.disk(ctx.config, prebuild), clone, ctx),
             :ok <- Machine.impl(ctx.config).adopt(p.env_id, nonce, guest, ctx.config) do
          File.ln(clone, paths.data)
        end
      after
        discard_adoption(stage, nonce, ctx.config)
      end
    end
  end

  defp recover_provisioning(config) do
    for path <- Path.wildcard(Path.join(config.vm_root, ".*"), match_dot: true) do
      name = Path.basename(path)

      cond do
        Regex.match?(~r/\A\.disk-[A-Za-z0-9_-]{22}==\.seed\z/, name) ->
          VM.remove_tree(path)

        Regex.match?(~r/\A\.adopt-[0-9a-f]{32}(\.discard)?\z/, name) ->
          discard_adoption(path, binary_part(name, 7, 32), config)

        true ->
          :ok
      end
    end
  end

  defp discard_adoption(path, nonce, config) do
    # Fence a helper request that has not started its transient unit yet.
    # The old pathname disappears before we stop any registered unit.
    discard = String.trim_trailing(path, ".discard") <> ".discard"

    result =
      with :ok <- File.rename(path, discard),
           :ok <- Machine.impl(config).stop_adoption(nonce, config) do
        VM.remove_tree(discard)
      end

    if result != :ok do
      Logger.warning("could not discard prebuild staging #{path}: #{inspect(result)}")
    end
  end

  defp format_new_disk(dest, env_id, ctx) do
    # mkfs only sees a new file in the agent-owned parent. Link it into
    # place once complete, failing if another disk appeared meanwhile.
    tmp =
      Path.join(ctx.config.vm_root, ".disk-" <> Base.url_encode64(:crypto.strong_rand_bytes(16)))

    args = [
      "-q",
      "-F",
      "-L",
      "fm-data",
      "-d",
      tmp <> ".seed",
      "-E",
      "nodiscard,lazy_itable_init=1,lazy_journal_init=1",
      tmp,
      "#{ctx.config.vm_disk_gb}G"
    ]

    try do
      File.mkdir!(tmp <> ".seed")
      File.write!(Path.join(tmp <> ".seed", ".env-id"), env_id <> "\n")

      case ctx.runner.run("mkfs.ext4", args, timeout: 120_000) do
        {:ok, %{status: 0}} ->
          File.ln(tmp, dest)

        {:ok, %{output: output}} ->
          {:error, "couldn't format the new data disk: #{String.slice(output, -500, 500)}"}

        {:error, reason} ->
          {:error, "couldn't format the new data disk: #{inspect(reason)}"}
      end
    after
      File.rm(tmp)
      File.rm_rf!(tmp <> ".seed")
    end
  end

  defp ensure_root_disk(p, paths, guest, ctx, log) do
    meta =
      case VM.read_meta(ctx.config, p.env_id) do
        {:ok, meta} -> meta
        {:error, :none} -> %{}
      end

    cond do
      meta["guest"] == guest.digest and File.exists?(paths.root) ->
        {:ok, Map.put(meta, "slug", p.slug)}

      # A running VM keeps the disk it booted; the next boot gets the new one.
      File.exists?(paths.root) and Machine.impl(ctx.config).running?(p.env_id, ctx.config) ->
        {:ok, Map.put(meta, "slug", p.slug)}

      true ->
        copy_root_disk(p, paths, guest, meta, ctx, log)
    end
  end

  defp copy_root_disk(p, paths, guest, meta, ctx, log) do
    if meta["guest"], do: log.("info", "Moving the environment to a new guest image\n")

    with :ok <- copy_disk(Path.join(guest.dir, "root.raw"), paths.root, ctx) do
      {:ok, Map.merge(meta, %{"slug" => p.slug, "guest" => guest.digest})}
    end
  end

  # A reflink where the filesystem has them (XFS, btrfs), a sparse copy
  # otherwise, put in place once it's whole.
  defp copy_disk(source, dest, ctx) do
    # Stage the copy under the agent-owned parent, outside the writable VM directory.
    tmp =
      Path.join(
        Path.dirname(Path.dirname(dest)),
        ".disk-" <> Base.url_encode64(:crypto.strong_rand_bytes(16))
      )

    try do
      case ctx.runner.run("cp", ["--reflink=auto", "--sparse=always", source, tmp],
             timeout: 600_000
           ) do
        {:ok, %{status: 0}} -> File.rename(tmp, dest)
        other -> {:error, "couldn't copy #{Path.basename(source)}: #{inspect(other)}"}
      end
    after
      File.rm(tmp)
    end
  end

  # {:ok, :running | :booted | :resumed}
  defp ensure_running(env_id, spec, ctx, log, op_id \\ nil) do
    machine = Machine.impl(ctx.config)
    snapshot = VM.paths(ctx.config, env_id).snapshot

    cond do
      machine.running?(env_id, ctx.config) ->
        with :ok <- machine.unpause(env_id, ctx.config),
             :ok <- finish_pending_restore(env_id, snapshot, ctx) do
          {:ok, :running}
        end

      VM.suspended?(ctx.config, env_id) ->
        case restore(env_id, spec, ctx, log, op_id) do
          :ok ->
            {:ok, :resumed}

          {:error, message} ->
            # The disk is as the VM left it, mid-flight; booting it is like
            # after a power cut, which beats not starting at all.
            log.("info", "Couldn't resume the environment (#{message}); booting it instead\n")
            discard_snapshot(ctx.config, env_id, ctx.runner)
            with :ok <- boot(env_id, spec, ctx, log), do: {:ok, :booted}
        end

      true ->
        # A snapshot a VM was started from once, which went down since.
        discard_snapshot(ctx.config, env_id, ctx.runner)
        with :ok <- boot(env_id, spec, ctx, log), do: {:ok, :booted}
    end
  end

  # Cloud Hypervisor may still be reading a snapshot left by an interrupted restore.
  defp finish_pending_restore(env_id, snapshot, ctx) do
    if File.exists?(snapshot) do
      with :ok <- await(env_id, ctx, "didn't answer"),
           do: discard_snapshot(ctx.config, env_id, ctx.runner)
    else
      :ok
    end
  end

  # What the VM booted with, which a resume needs to match.
  defp boot(env_id, spec, ctx, log) do
    log.("info", "Booting the environment's VM\n")

    with :ok <- set_resume_id(ctx.config, env_id, nil),
         :ok <- Machine.impl(ctx.config).boot(env_id, spec, ctx.config),
         :ok <- await(env_id, ctx, "didn't come up") do
      log.("info", "VM running (agent #{spec.agent_version})\n")

      with {:ok, meta} <- VM.read_meta(ctx.config, env_id) do
        booted = %{
          "agent" => spec.agent_version,
          "guest" => spec.guest,
          "cpus" => spec.cpus,
          "memory_mb" => spec.memory_mb
        }

        VM.write_meta(ctx.config, env_id, Map.put(meta, "booted", booted))
      end

      :ok
    end
  end

  # The guest's clock is stepped to the box's when the link says hello;
  # the secrets go again after (they may have changed while it was
  # suspended). The snapshot goes once the guest has said hello from it,
  # not before: the helper's unit starts Cloud Hypervisor and returns, and
  # Cloud Hypervisor reads the snapshot after. Copy-on-write keeps the
  # pages the VM maps once it's running. One left behind (the agent
  # stopped in between) is found beside a running VM and deleted then
  # (ensure_running/4, recover/1), never restored over a disk the VM has
  # changed since.
  defp restore(env_id, spec, ctx, log, op_id) do
    log.("info", "Resuming the environment's VM\n")
    snapshot = VM.paths(ctx.config, env_id).snapshot

    # On disk before the VM can run from it: whatever happens next, this
    # snapshot is never restored again (VM.suspended?/2). Made new, so not
    # written through anything the VM left in its place.
    with :ok <- set_resume_id(ctx.config, env_id, op_id),
         :ok <- mark_consumed(snapshot, ctx.runner),
         :ok <- Machine.impl(ctx.config).restore(env_id, spec, ctx.config),
         :ok <- await(env_id, ctx, "didn't come back from its snapshot") do
      discard_snapshot(ctx.config, env_id, ctx.runner)
      log.("info", "VM resumed\n")
      :ok
    end
  end

  defp mark_consumed(snapshot, runner) do
    case File.write(Path.join(snapshot, "consumed"), "", [:exclusive]) do
      :ok ->
        sync_path!(snapshot, runner)

      {:error, reason} ->
        {:error, "couldn't mark its snapshot used (#{:file.format_error(reason)})"}
    end
  end

  defp await(env_id, ctx, what) do
    case Links.await(env_id, ctx.config, ctx.config.vm_boot_timeout) do
      :ok ->
        :ok

      :timeout ->
        Machine.impl(ctx.config).kill(env_id, ctx.config)

        {:error,
         "the environment's VM #{what}; its console is in #{VM.paths(ctx.config, env_id).serial}"}
    end
  end

  # Before anything that brings the environment up: the guest's secrets
  # are on its own tmpfs, so a boot (or a reboot the guest did itself)
  # leaves it with none.
  defp push_secrets(env_id, log, ctx) do
    with {:ok, files} <- read_cached_secrets(ctx.config, env_id),
         {:ok, cmd} <- Command.new("env.secrets.write", %{env_id: env_id, files: files}),
         {:ok, _} <- relay(cmd, log, ctx) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, "couldn't write secrets: #{message}"}
      {:error, message, _} -> {:error, "couldn't write secrets: #{message}"}
      {:error, errors} -> {:error, "couldn't write secrets: #{inspect(errors)}"}
    end
  end

  defp cache_secrets(ctx, env_id, files, keep \\ []) do
    Env.run("env.secrets.write", %{env_id: env_id, files: files, keep: keep}, ctx)
  end

  defp read_cached_secrets(config, env_id) do
    dir = Path.join(config.secrets_root, env_id)

    Enum.reduce_while(Schema.secret_files(), {:ok, %{}}, fn name, {:ok, files} ->
      case File.read(Path.join(dir, name)) do
        {:ok, content} ->
          {:cont, {:ok, Map.put(files, name, content)}}

        {:error, :enoent} ->
          {:cont, {:ok, files}}

        {:error, reason} ->
          {:halt, {:error, "couldn't read cached #{name}: #{:file.format_error(reason)}"}}
      end
    end)
  end
end
