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
  alias ForemanAgent.VM.{Image, Link, Links, Machine}
  alias ForemanProtocol.{Command, Schema}

  # How long a guest gets to shut down before the VM is stopped.
  @power_off_timeout 60_000

  @spec run(Command.t(), (String.t(), String.t() -> any()), map()) ::
          {:ok, map()} | {:error, String.t()} | {:error, String.t(), map()}
  def run(%Command{type: type, payload: p} = cmd, log, ctx)
      when type in ["env.create", "env.rebuild"] do
    with :ok <- Env.check_clone_url(p.clone_url, ctx.config),
         {:ok, _} <- cache_secrets(ctx, p.env_id, p.files),
         {:ok, spec} <- prepare(p, ctx, log),
         {:ok, _how} <- ensure_running(p.env_id, spec, ctx, log),
         :ok <- push_secrets(p.env_id, log, ctx) do
      relay(cmd, log, ctx)
    end
  end

  # A start that resumed the VM says so: the environment's processes kept
  # the secrets they had when it was suspended.
  def run(%Command{type: "env.start", payload: p} = cmd, log, ctx) do
    with {:ok, meta} <- existing(ctx.config, p.env_id),
         {:ok, spec} <- prepare(Map.put(p, :limits, limits(meta)), ctx, log),
         {:ok, how} <- ensure_running(p.env_id, spec, ctx, log),
         :ok <- push_secrets(p.env_id, log, ctx) do
      case relay(cmd, log, ctx) do
        {:ok, result} when how == :resumed -> {:ok, Map.put(result, "resumed", true)}
        other -> other
      end
    end
  end

  def run(%Command{type: "env.suspend", payload: p}, log, ctx) do
    machine = Machine.impl(ctx.config)
    paths = VM.paths(ctx.config, p.env_id)

    cond do
      machine.running?(p.env_id, ctx.config) ->
        log.("info", "Saving the environment's VM to disk\n")
        tmp = paths.snapshot <> ".tmp"
        File.rm_rf!(tmp)
        File.mkdir_p!(tmp)
        File.chmod!(tmp, 0o700)

        case machine.snapshot(p.env_id, tmp, ctx.config) do
          :ok ->
            Links.stop(p.env_id)
            # On disk before it counts: a power cut after this mustn't
            # leave a torn snapshot that looks whole.
            sync_dir(tmp)
            File.rm_rf!(paths.snapshot)
            File.rename!(tmp, paths.snapshot)
            {:ok, %{"suspended" => true}}

          {:error, message} ->
            File.rm_rf(tmp)
            {:error, message}
        end

      VM.suspended?(ctx.config, p.env_id) ->
        {:ok, %{"suspended" => true}}

      true ->
        {:error, "the environment isn't running"}
    end
  end

  def run(%Command{type: "env.stop", payload: p} = cmd, log, ctx) do
    machine = Machine.impl(ctx.config)

    # A suspended environment comes back first, so its own stop runs.
    if VM.suspended?(ctx.config, p.env_id), do: resume(p, log, ctx)

    if machine.running?(p.env_id, ctx.config) do
      # A guest that never finishes its part doesn't keep the VM up: it's
      # shut down either way, which stops the environment as surely.
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

        {:error, message} ->
          {:error, message}
      end
    else
      {:ok, %{}}
    end
  end

  def run(%Command{type: "env.secrets.write", payload: p} = cmd, log, ctx) do
    with {:ok, result} <- cache_secrets(ctx, p.env_id, p.files, Map.get(p, :keep, [])) do
      if Machine.impl(ctx.config).running?(p.env_id, ctx.config),
        do: relay(cmd, log, ctx),
        else: {:ok, result}
    end
  end

  def run(%Command{type: "env.destroy", payload: p}, log, ctx) do
    machine = Machine.impl(ctx.config)
    log.("info", "Removing the environment's VM\n")
    Links.stop(p.env_id)

    with :ok <- machine.release(p.env_id, ctx.config) do
      File.rm_rf(VM.paths(ctx.config, p.env_id).dir)
      File.rm_rf(Path.join(ctx.config.secrets_root, p.env_id))
      {:ok, %{}}
    end
  end

  # restart, logs, git_status and connect need the environment running.
  # A restart brings the containers up again, so the secrets go first.
  def run(%Command{type: type, payload: p} = cmd, log, ctx) do
    cond do
      not Machine.impl(ctx.config).running?(p.env_id, ctx.config) ->
        {:error, "the environment isn't running"}

      type == "env.restart" ->
        with :ok <- push_secrets(p.env_id, log, ctx), do: relay(cmd, log, ctx)

      true ->
        relay(cmd, log, ctx)
    end
  end

  defp resume(p, log, ctx) do
    with {:ok, meta} <- existing(ctx.config, p.env_id),
         {:ok, spec} <-
           prepare(Map.merge(p, %{slug: meta["slug"], limits: limits(meta)}), ctx, log) do
      with {:ok, _how} <- ensure_running(p.env_id, spec, ctx, log), do: :ok
    end
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

    for env_id <- VM.list(config) do
      paths = VM.paths(config, env_id)
      File.rm_rf(paths.snapshot <> ".tmp")

      if machine.running?(env_id, config) do
        File.rm_rf(paths.snapshot)
        _ = machine.unpause(env_id, config)
      end
    end

    :ok
  end

  defp sync_dir(dir) do
    for name <- File.ls!(dir), path = Path.join(dir, name), File.regular?(path) do
      {:ok, fd} = :file.open(path, [:read, :raw])
      :ok = :file.sync(fd)
      :file.close(fd)
    end

    :ok
  end

  defp relay(cmd, log, ctx, opts \\ []),
    do: Link.run(Links.get(cmd.payload.env_id, ctx.config), cmd, log, opts)

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

  defp limits(%{"cpus" => cpus, "memory_mb" => memory}), do: %{cpus: cpus, memory_mb: memory}
  defp limits(_meta), do: %{}

  # The VM's directory, disks and record. The root disk is made again
  # whenever the guest image changes: the environment keeps nothing there.
  defp prepare(p, ctx, log) do
    config = ctx.config
    paths = VM.paths(config, p.env_id)

    with {:ok, guest} <- Image.ensure_guest(config, log),
         {:ok, agent} <- Image.ensure_agent_disk(config, ctx.runner, log),
         :ok <- File.mkdir_p(paths.dir),
         :ok <- File.chmod(paths.dir, 0o700),
         :ok <- ensure_data_disk(paths, config),
         p = keep_snapshot_compatible(p, guest, agent, ctx, log),
         {:ok, meta} <- ensure_root_disk(p, paths, guest, ctx, log) do
      size = VM.size(Map.get(p, :limits, %{}), config, VM.box_size(config.proc))

      meta =
        Map.merge(meta, %{
          "cpus" => size.cpus,
          "memory_mb" => size.memory_mb,
          "agent" => agent.version
        })

      VM.write_meta(config, p.env_id, meta)

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
  defp keep_snapshot_compatible(p, guest, agent, ctx, log) do
    config = ctx.config

    with true <- VM.suspended?(config, p.env_id),
         false <- Machine.impl(config).running?(p.env_id, config),
         {:ok, %{"booted" => booted}} <- VM.read_meta(config, p.env_id) do
      if booted["agent"] == agent.version and booted["guest"] == guest.digest do
        Map.put(p, :limits, %{cpus: booted["cpus"], memory_mb: booted["memory_mb"]})
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
    File.rm_rf(VM.paths(config, p.env_id).snapshot)
    p
  end

  defp ensure_data_disk(paths, config) do
    if File.exists?(paths.data) do
      :ok
    else
      # Sparse: the guest formats it on first boot, and it takes space as
      # the environment fills it.
      with {:ok, fd} <- :file.open(paths.data, [:write, :raw]),
           {:ok, _} <- :file.position(fd, config.vm_disk_gb * 1024 * 1024 * 1024),
           :ok <- :file.truncate(fd) do
        :file.close(fd)
      end
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
    tmp = paths.root <> ".tmp"
    _ = File.rm(tmp)
    source = Path.join(guest.dir, "root.raw")

    # A reflink where the filesystem has them (XFS, btrfs), a sparse copy
    # otherwise.
    case ctx.runner.run("cp", ["--reflink=auto", "--sparse=always", source, tmp],
           timeout: 600_000
         ) do
      {:ok, %{status: 0}} ->
        File.rename!(tmp, paths.root)
        {:ok, Map.merge(meta, %{"slug" => p.slug, "guest" => guest.digest})}

      other ->
        _ = File.rm(tmp)
        {:error, "couldn't copy the guest image: #{inspect(other)}"}
    end
  end

  # {:ok, :running | :booted | :resumed}
  defp ensure_running(env_id, spec, ctx, log) do
    machine = Machine.impl(ctx.config)
    snapshot = VM.paths(ctx.config, env_id).snapshot

    cond do
      machine.running?(env_id, ctx.config) ->
        # Never restored: the VM has run since it was taken.
        File.rm_rf(snapshot)
        with :ok <- machine.unpause(env_id, ctx.config), do: {:ok, :running}

      VM.suspended?(ctx.config, env_id) ->
        case restore(env_id, spec, ctx, log) do
          :ok ->
            {:ok, :resumed}

          {:error, message} ->
            # The disk is as the VM left it, mid-flight; booting it is like
            # after a power cut, which beats not starting at all.
            log.("info", "Couldn't resume the environment (#{message}); booting it instead\n")
            File.rm_rf(snapshot)
            with :ok <- boot(env_id, spec, ctx, log), do: {:ok, :booted}
        end

      true ->
        with :ok <- boot(env_id, spec, ctx, log), do: {:ok, :booted}
    end
  end

  # What the VM booted with, which a resume needs to match.
  defp boot(env_id, spec, ctx, log) do
    log.("info", "Booting the environment's VM\n")

    with :ok <- Machine.impl(ctx.config).boot(env_id, spec, ctx.config),
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
  # suspended). The snapshot goes as soon as the VM is running from it:
  # copy-on-write keeps the pages the VM maps, and a snapshot left behind
  # would be restored over a disk the VM has changed since.
  defp restore(env_id, spec, ctx, log) do
    log.("info", "Resuming the environment's VM\n")

    with :ok <- Machine.impl(ctx.config).restore(env_id, spec, ctx.config) do
      File.rm_rf(VM.paths(ctx.config, env_id).snapshot)

      with :ok <- await(env_id, ctx, "didn't come back from its snapshot") do
        log.("info", "VM resumed\n")
        :ok
      end
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
    files = read_cached_secrets(ctx.config, env_id)

    with {:ok, cmd} <- Command.new("env.secrets.write", %{env_id: env_id, files: files}),
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

    for name <- Schema.secret_files(),
        {:ok, content} <- [File.read(Path.join(dir, name))],
        into: %{},
        do: {name, content}
  end
end
