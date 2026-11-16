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
  sidecars get theirs), and destroy throws the VM's disks away.
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
         :ok <- ensure_running(p.env_id, spec, ctx, log) do
      relay(cmd, log, ctx)
    end
  end

  def run(%Command{type: "env.start", payload: p} = cmd, log, ctx) do
    with {:ok, meta} <- existing(ctx.config, p.env_id),
         {:ok, spec} <- prepare(Map.put(p, :limits, limits(meta)), ctx, log),
         :ok <- ensure_running(p.env_id, spec, ctx, log) do
      relay(cmd, log, ctx)
    end
  end

  def run(%Command{type: "env.stop", payload: p} = cmd, log, ctx) do
    machine = Machine.impl(ctx.config)

    if machine.running?(p.env_id, ctx.config) do
      result = relay(cmd, log, ctx)
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
  def run(%Command{payload: p} = cmd, log, ctx) do
    if Machine.impl(ctx.config).running?(p.env_id, ctx.config),
      do: relay(cmd, log, ctx),
      else: {:error, "the environment isn't running"}
  end

  defp relay(cmd, log, ctx), do: Link.run(Links.get(cmd.payload.env_id, ctx.config), cmd, log)

  defp existing(config, env_id) do
    case VM.read_meta(config, env_id) do
      {:ok, meta} ->
        {:ok, meta}

      {:error, :none} ->
        {:error, "this environment has no VM on this box; rebuild it to make one"}
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

  defp ensure_running(env_id, spec, ctx, log) do
    machine = Machine.impl(ctx.config)

    if machine.running?(env_id, ctx.config) do
      :ok
    else
      log.("info", "Booting the environment's VM\n")

      with :ok <- machine.boot(env_id, spec, ctx.config) do
        case Links.await(env_id, ctx.config, ctx.config.vm_boot_timeout) do
          :ok ->
            log.("info", "VM running (agent #{spec.agent_version})\n")
            push_secrets(env_id, log, ctx)

          :timeout ->
            {:error,
             "the environment's VM didn't come up; its console is in #{VM.paths(ctx.config, env_id).serial}"}
        end
      end
    end
  end

  # After a boot: the guest's secrets are on its own tmpfs, so they start
  # out empty.
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
