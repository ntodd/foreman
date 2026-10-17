defmodule ForemanAgent.Env.Vm do
  @moduledoc """
  Environments that each run in their own VM, on a box with
  `FOREMAN_ISOLATION=vm`.

  Each environment gets an Incus VM (`ForemanAgent.Vm.Incus`) with its own
  kernel and its own Docker. The clone, Docker's images and volumes, and
  the secrets the containers see all live on the VM's disk and tmpfs, so
  an escape from a container lands in that VM, which holds nothing but
  this environment.

  The work inside the VM is the same code as on a container box: this
  agent's own release is copied into the VM, and each operation runs
  there once as `ForemanAgent.Guest`, which calls `ForemanAgent.Env` with
  the VM's paths and Docker. The host only manages the VM, hands each
  operation over (`ForemanAgent.Guest.Wire`), and relays what comes back.
  It never reads the clone, so the symlink and file-policy checks guard
  the VM's own state rather than the box.

  The host keeps a copy of each environment's secrets in its tmpfs
  (`<secrets_root>/<env_id>`), so a VM that was stopped or rebooted gets
  them back on start without waiting for the control plane.
  """

  alias ForemanAgent.{Config, Env, Inventory, SafeFS}
  alias ForemanAgent.Guest.Wire
  alias ForemanAgent.Vm.Incus

  # Inside every VM; the image (priv/vm/provision.sh) sets these up.
  @guest_user "foreman"
  @guest_uid 1990
  @guest_home "/var/lib/foreman-agent"
  @guest_ops "/var/lib/foreman-agent/ops"
  @guest_lock "/var/lib/foreman-agent/op.lock"
  @guest_releases "/opt/foreman-agent/releases"
  @guest_devcontainer "/opt/foreman-agent/node/node_modules/.bin/devcontainer"

  # A little over the guest's own limits (Env's), so its message wins.
  @up_timeout :timer.minutes(170)
  @op_timeout :timer.minutes(35)
  @kill_grace 10_000

  @spec run(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(type, p, ctx) when type in ["env.create", "env.rebuild"], do: up(type, p, ctx)
  def run("env.start", p, ctx), do: start(p, ctx)
  def run("env.stop", p, ctx), do: stop(p, ctx)
  def run("env.restart", p, ctx), do: restart(p, ctx)
  def run("env.destroy", p, ctx), do: destroy(p, ctx)
  def run("env.secrets.write", p, ctx), do: write_secrets(p, ctx)
  def run(type, p, ctx) when type in ["env.logs", "env.git_status"], do: in_running(type, p, ctx)

  # -- lifecycle ------------------------------------------------------------

  defp up(type, p, ctx) do
    name = Incus.name(p.env_id)

    with {:ok, _} <- host_secrets(p.env_id, p.files, [], ctx),
         {:ok, size} <- ensure_vm(ctx, name, p, create: true),
         :ok <- ensure_release(ctx, name),
         {:ok, result} <- guest(ctx, name, type, guest_payload(p, ctx), @up_timeout) do
      {:ok, Map.merge(result, %{"isolation" => "vm", "vm" => size})}
    end
  end

  # The registry credential is the owner's, shared by all its repos. On a
  # container box it stays in the agent's own directory; a VM is the
  # environment's, root in it is the environment's, and the credential
  # would be readable there. So it goes in only where the box says so.
  defp guest_payload(%{registry_auth: [_ | _] = auths} = p, ctx) do
    if ctx.config.vm_registry_auth do
      p
    else
      hosts = Enum.map_join(auths, ", ", & &1.host)

      ctx.log.(
        "info",
        "not passing the registry credential into the VM (FOREMAN_VM_REGISTRY_AUTH=allow would); " <>
          "private images from #{hosts} won't pull\n"
      )

      Map.delete(p, :registry_auth)
    end
  end

  defp guest_payload(p, _ctx), do: p

  defp start(p, ctx) do
    name = Incus.name(p.env_id)

    with {:ok, size} <- ensure_vm(ctx, name, p, create: false),
         :ok <- ensure_release(ctx, name),
         {:ok, _} <- restore_secrets(ctx, name, p.env_id),
         {:ok, result} <- guest(ctx, name, "env.start", p, @up_timeout) do
      {:ok, Map.merge(result, %{"isolation" => "vm", "vm" => size})}
    end
  end

  # The containers stop first, so their stop_grace_period and any cleanup
  # a sidecar does on stop still happen; then the VM, which frees its
  # memory for the rest of the box.
  defp stop(p, ctx) do
    name = Incus.name(p.env_id)

    case Incus.state(ctx, name) do
      {:ok, :running} ->
        with {:error, message} <- guest(ctx, name, "env.stop", p, @op_timeout) do
          ctx.log.(
            "info",
            "stopping the containers failed (#{message}); shutting the VM down anyway\n"
          )
        end

        ctx.log.("info", "shutting down the VM #{name}\n")

        with :ok <- Incus.stop(ctx, name), do: {:ok, %{"vm" => "stopped"}}

      {:ok, :other} ->
        ctx.log.("info", "the VM #{name} isn't running normally; stopping it by force\n")
        with :ok <- Incus.stop(ctx, name, force: true), do: {:ok, %{"vm" => "stopped"}}

      {:ok, _} ->
        {:ok, %{"vm" => "stopped"}}

      error ->
        error
    end
  end

  defp restart(p, ctx) do
    name = Incus.name(p.env_id)

    with {:ok, _} <- ensure_vm(ctx, name, p, create: false),
         :ok <- ensure_release(ctx, name),
         {:ok, _} <- restore_secrets(ctx, name, p.env_id) do
      guest(ctx, name, "env.restart", p, @up_timeout)
    end
  end

  # Deleting the VM deletes its disk: the clone, images and volumes. What
  # the host holds is only the secrets copy and scratch files.
  defp destroy(p, ctx) do
    name = Incus.name(p.env_id)

    with {:ok, state} <- Incus.state(ctx, name),
         :ok <- if(state == :missing, do: :ok, else: Incus.delete(ctx, name)) do
      paths = Env.paths(ctx.config, p.env_id)
      File.rm_rf(paths.env_dir)
      File.rm_rf(paths.secrets)
      {:ok, %{}}
    end
  end

  defp write_secrets(p, ctx) do
    name = Incus.name(p.env_id)
    keep = Map.get(p, :keep, [])

    with {:ok, result} <- host_secrets(p.env_id, p.files, keep, ctx),
         {:ok, state} <- Incus.state(ctx, name) do
      if state == :running do
        with :ok <- ensure_release(ctx, name),
             {:ok, _} <- guest(ctx, name, "env.secrets.write", p, @op_timeout),
             do: {:ok, result}
      else
        {:ok, result}
      end
    end
  end

  defp in_running(type, p, ctx) do
    name = Incus.name(p.env_id)

    case Incus.state(ctx, name) do
      {:ok, :running} ->
        with :ok <- ensure_release(ctx, name), do: guest(ctx, name, type, p, @op_timeout)

      {:ok, :missing} ->
        {:error, "this box has no VM for the environment"}

      {:ok, _} ->
        {:error, "the environment's VM is stopped"}

      error ->
        error
    end
  end

  # -- the VM -----------------------------------------------------------------

  # Create and rebuild bring the VM to the size asked for; start and
  # restart use it as it is, and report its real size.
  defp ensure_vm(ctx, name, p, opts) do
    wanted = size(ctx.config, Map.get(p, :limits))

    with {:ok, info} <- Incus.info(ctx, name),
         {:ok, size} <- bring_up(ctx, name, p, info, wanted, opts[:create]),
         :ok <- Incus.wait_ready(ctx, name) do
      {:ok, Map.put(size, "name", name)}
    end
  end

  defp bring_up(_ctx, _name, _p, :missing, _wanted, false),
    do: {:error, "this box has no VM for the environment; rebuild it"}

  defp bring_up(ctx, name, p, :missing, wanted, true) do
    ctx.log.(
      "info",
      "creating the VM #{name}: #{wanted["cpus"]} vCPUs, #{wanted["memory_mb"]} MB\n"
    )

    with :ok <-
           Incus.create(ctx, name,
             env_id: p.env_id,
             slug: p.slug,
             cpus: wanted["cpus"],
             memory_mb: wanted["memory_mb"],
             disk_gb: ctx.config.vm_disk_gb
           ),
         :ok <- boot(ctx, name) do
      {:ok, wanted}
    end
  end

  defp bring_up(ctx, name, _p, info, wanted, true) do
    if info.cpus == wanted["cpus"] and info.memory_mb == wanted["memory_mb"] do
      with :ok <- running(ctx, name, info), do: {:ok, wanted}
    else
      # A VM's memory can't change while it runs.
      ctx.log.(
        "info",
        "resizing the VM #{name} to #{wanted["cpus"]} vCPUs, #{wanted["memory_mb"]} MB\n"
      )

      with :ok <- if(info.status == :stopped, do: :ok, else: Incus.stop(ctx, name)),
           :ok <- Incus.resize(ctx, name, wanted["cpus"], wanted["memory_mb"]),
           :ok <- boot(ctx, name) do
        {:ok, wanted}
      end
    end
  end

  defp bring_up(ctx, name, _p, info, wanted, false) do
    with :ok <- running(ctx, name, info) do
      {:ok,
       %{
         "cpus" => info.cpus || wanted["cpus"],
         "memory_mb" => info.memory_mb || wanted["memory_mb"]
       }}
    end
  end

  defp running(_ctx, _name, %{status: :running}), do: :ok
  defp running(ctx, name, _info), do: boot(ctx, name)

  defp boot(ctx, name) do
    ctx.log.("info", "starting the VM #{name}\n")
    Incus.start(ctx, name)
  end

  @doc false
  def size(config, limits) do
    cpus =
      case limits do
        %{cpus: cpus} when is_number(cpus) -> max(ceil(cpus), 1)
        _ -> config.vm_cpus || :erlang.system_info(:logical_processors_available)
      end

    memory =
      case limits do
        %{memory_mb: mb} when is_integer(mb) -> mb
        _ -> config.vm_memory_mb
      end

    %{"cpus" => cpus, "memory_mb" => memory}
  end

  # The guest runs this agent's exact release, so the two always agree on
  # the request format and on what an environment is.
  defp ensure_release(ctx, name) do
    dest = guest_release(ctx)

    case Incus.exec(ctx, name, ["test", "-x", Path.join(dest, "bin/foreman_agent")],
           timeout: 30_000
         ) do
      {:ok, %{status: 0}} -> :ok
      _ -> push_release(ctx, name, dest)
    end
  end

  defp push_release(ctx, name, dest) do
    ctx.log.("info", "copying the agent release into the VM\n")

    # Unpacked beside its final path and renamed, so an interrupted copy
    # is never mistaken for a release.
    script = ~S"""
    tar -C "$1" -cf - . | "$0" exec "$2" -- sh -c 'rm -rf "$1.partial" && mkdir -p "$1.partial" && tar -C "$1.partial" -xf - && chown -R "$2" "$1.partial" && mv "$1.partial" "$1"' sh "$3" "$4"
    """

    args = [
      ctx.config.incus,
      release_dir(ctx.config),
      name,
      dest,
      "#{@guest_user}:#{@guest_user}"
    ]

    case ctx.runner.run("sh", ["-c", String.trim(script) | args],
           env: %{},
           timeout: :timer.minutes(10)
         ) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{output: output}} ->
        {:error, "couldn't copy the agent into the VM: #{String.trim(output)}"}

      {:error, reason} ->
        {:error, "couldn't copy the agent into the VM: #{inspect(reason)}"}
    end
  end

  defp release_dir(config), do: config.vm_release_dir || to_string(:code.root_dir())

  defp guest_release(_ctx), do: Path.join(@guest_releases, release_id())

  # The version plus a digest of the agent's own code, so a rebuild that
  # keeps the version number still replaces the copy in each VM.
  @doc false
  def release_id do
    case :persistent_term.get({__MODULE__, :release_id}, nil) do
      nil ->
        vsn = :foreman_agent |> Application.spec(:vsn) |> to_string()

        modules =
          Application.spec(:foreman_agent, :modules) ++
            (Application.spec(:foreman_protocol, :modules) || [])

        id = "#{vsn}-#{release_digest(modules, [Config.get().feature_dir])}"
        :persistent_term.put({__MODULE__, :release_id}, id)
        id

      id ->
        id
    end
  end

  @doc false
  # The modules' object code and the files under `dirs` (the feature the
  # guest puts in every environment), hashed together.
  def release_digest(modules, dirs) do
    code =
      for mod <- Enum.sort(modules) do
        case :code.get_object_code(mod) do
          {^mod, beam, _} -> :erlang.md5(beam)
          :error -> Atom.to_string(mod)
        end
      end

    files =
      for dir <- dirs,
          dir,
          path <- Enum.sort(Path.wildcard(Path.join(dir, "**"), match_dot: true)),
          File.regular?(path) do
        [Path.relative_to(path, dir), :erlang.md5(File.read!(path))]
      end

    :sha256 |> :crypto.hash([code, files]) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  # -- secrets --------------------------------------------------------------

  defp host_secrets(env_id, files, keep, ctx) do
    Env.run("env.secrets.write", %{env_id: env_id, files: files, keep: keep}, ctx)
  end

  defp restore_secrets(ctx, name, env_id) do
    dir = Env.paths(ctx.config, env_id).secrets

    files =
      for file <- ForemanProtocol.Schema.secret_files(),
          {:ok, content} <- [File.read(Path.join(dir, file))],
          into: %{},
          do: {file, content}

    guest(ctx, name, "env.secrets.write", %{env_id: env_id, files: files, keep: []}, @op_timeout)
  end

  # -- running an operation in the guest ---------------------------------------

  defp guest(ctx, name, type, payload, timeout) do
    id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    remote = Path.join(@guest_ops, id <> ".op")

    with :ok <- hand_over(ctx, name, id, remote, Wire.request(type, payload)) do
      watchdog = watch(ctx, name, id)

      try do
        relay(ctx, name, type, remote, id, timeout)
      after
        send(watchdog, :done)
      end
    end
  end

  # Staged on the secrets tmpfs, like the secrets themselves: the request
  # carries them. A killed operation can't run its `after`, so anything
  # older than an hour is a leftover and goes.
  defp hand_over(ctx, name, id, remote, request) do
    dir = Path.join(ctx.config.secrets_root, ".vm-ops")
    local = Path.join(dir, id <> ".op")

    try do
      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           :ok <- sweep(dir),
           :ok <- SafeFS.write_atomic(local, request, 0o600) do
        Incus.push(ctx, name, local, remote, uid: @guest_uid, gid: @guest_uid, mode: 0o600)
      else
        {:error, reason} when not is_binary(reason) ->
          {:error, "couldn't hand the operation over: #{inspect(reason)}"}

        error ->
          error
      end
    after
      File.rm(local)
    end
  end

  defp sweep(dir) do
    cutoff = System.os_time(:second) - 3600

    for path <- Path.wildcard(Path.join(dir, "*.op")),
        {:ok, %File.Stat{mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime < cutoff,
        do: File.rm(path)

    :ok
  end

  defp relay(ctx, name, type, remote, id, timeout) do
    key = {__MODULE__, id}
    Process.put(key, %{buffer: Wire.decoder(), result: nil, noise: []})

    on_output = fn chunk ->
      state = Process.get(key)
      {events, buffer} = Wire.feed(state.buffer, chunk)
      Process.put(key, Enum.reduce(events, %{state | buffer: buffer}, &event(ctx, &1, &2)))
    end

    run =
      Incus.exec(ctx, name, guest_argv(ctx, remote),
        cwd: @guest_home,
        env: guest_env(ctx, id),
        on_output: on_output,
        keep: 4_096,
        timeout: timeout
      )

    state = Process.delete(key)

    case {run, state.result} do
      {{:ok, %{status: :timeout}}, _} ->
        kill(ctx, name, id)
        {:error, "#{type} timed out in the VM"}

      {{:ok, _}, {:ok, _} = ok} ->
        ok

      {{:ok, _}, {:error, _} = error} ->
        error

      {{:ok, %{status: status}}, nil} ->
        noise = state.noise |> Enum.take(10) |> Enum.reverse() |> Enum.join("\n")
        {:error, "the VM's runner exited (#{status}) without a result: #{noise}"}

      {{:error, reason}, _} ->
        {:error, "couldn't run #{type} in the VM: #{inspect(reason)}"}
    end
  end

  defp event(ctx, {:log, stream, data}, state) do
    ctx.log.(stream, data)
    state
  end

  # The first result counts; a guest that prints more doesn't get to
  # change its answer.
  defp event(_ctx, {:result, result}, %{result: nil} = state), do: %{state | result: result}
  defp event(_ctx, {:result, _}, state), do: state
  defp event(_ctx, {:noise, ""}, state), do: state

  defp event(_ctx, {:noise, line}, state),
    do: %{state | noise: Enum.take([String.slice(line, 0, 500) | state.noise], 20)}

  # flock: an operation the host lost track of (the agent restarted mid
  # build) finishes before the next one for this environment starts.
  # setpriv: the guest user, with its groups (docker), which incus exec
  # --user wouldn't set.
  defp guest_argv(ctx, remote) do
    bin = Path.join(guest_release(ctx), "bin/foreman_agent")

    [
      "flock",
      @guest_lock,
      "setpriv",
      "--reuid=#{@guest_user}",
      "--regid=#{@guest_user}",
      "--init-groups",
      "--"
    ] ++
      [bin, "eval", ~s{ForemanAgent.Guest.main("#{remote}")}]
  end

  defp guest_env(ctx, id) do
    c = ctx.config

    %{
      "HOME" => @guest_home,
      "LANG" => "C.UTF-8",
      "PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "RELEASE_TMP" => Path.join(@guest_home, "tmp"),
      "FOREMAN_URL" => "",
      "FOREMAN_GUEST_OP" => id,
      "FOREMAN_AGENT_DATA_DIR" => @guest_home,
      "FOREMAN_ENVS_ROOT" => "/srv/foreman/envs",
      "FOREMAN_SECRETS_ROOT" => "/run/foreman/envs",
      "FOREMAN_RELEASE_ROOT" => "/opt/foreman-agent",
      "FOREMAN_DEVCONTAINER_CLI" => @guest_devcontainer,
      "FOREMAN_ALLOWED_GIT_HOSTS" => Enum.join(c.allowed_git_hosts, ","),
      "FOREMAN_INSECURE_GIT_HOSTS" => Enum.join(c.insecure_git_hosts, ","),
      "FOREMAN_POLICY" =>
        Enum.map_join(c.vm_policy_rules, ",", fn {rule, action} -> "#{rule}=#{action}" end)
    }
  end

  # The host's incus client dying (a cancel, a timeout, the agent
  # stopping) doesn't stop what it started in the VM, so the operation is
  # killed there by its id.
  defp watch(ctx, name, id) do
    caller = self()

    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        :done -> :ok
        {:DOWN, ^ref, _, _, :normal} -> :ok
        {:DOWN, ^ref, _, _, _} -> kill(ctx, name, id)
      end
    end)
  end

  defp kill(ctx, name, id) do
    pattern = "FOREMAN_GUEST_OP=#{id}"

    script = ~S"""
    for p in /proc/[0-9]*; do tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -qx "$1" && kill -s "$2" "${p#/proc/}"; done; true
    """

    for signal <- ["TERM", "KILL"] do
      Incus.exec(ctx, name, ["sh", "-c", String.trim(script), "sh", pattern, signal],
        timeout: 30_000
      )

      if signal == "TERM", do: Process.sleep(@kill_grace)
    end

    :ok
  end

  # -- inventory, stats, gc -------------------------------------------------------

  @doc """
  The environments on this box, from its VMs. A VM that's running but
  can't be asked about its containers is `partial`, never missing: the
  control plane recreates environments it thinks are missing.
  """
  @spec inventory(map()) :: {:ok, [map()]} | {:error, String.t()}
  def inventory(ctx) do
    with {:ok, vms} <- Incus.list(ctx) do
      envs =
        vms
        |> Enum.filter(&valid?/1)
        |> Task.async_stream(&vm_inventory(ctx, &1),
          max_concurrency: 8,
          timeout: 20_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(Enum.filter(vms, &valid?/1))
        |> Enum.map(fn
          {{:ok, env}, _vm} -> env
          {_timeout, vm} -> %{env_id: vm.env_id, slug: vm.slug, state: "partial", containers: []}
        end)

      {:ok, envs}
    end
  end

  defp valid?(vm) do
    match?(
      {:ok, _},
      ForemanProtocol.Schema.cast(%{"env_id" => vm.env_id, "slug" => vm.slug},
        env_id: {:uuid, required: true},
        slug: {:slug, required: true}
      )
    )
  end

  defp vm_inventory(_ctx, %{status: :stopped} = vm),
    do: %{env_id: vm.env_id, slug: vm.slug, state: "stopped", containers: []}

  defp vm_inventory(_ctx, %{status: :other} = vm), do: partial(vm)

  defp vm_inventory(ctx, vm) do
    filters = URI.encode_www_form(JSON.encode!(%{"label" => ["foreman.env_id=#{vm.env_id}"]}))
    url = "http://docker/containers/json?all=true&filters=#{filters}"
    argv = ["curl", "-sS", "--max-time", "10", "--unix-socket", "/var/run/docker.sock", url]

    with {:ok, %{status: 0, output: output}} <-
           Incus.exec(ctx, vm.name, argv, timeout: 15_000, keep: 4_000_000),
         {:ok, containers} when is_list(containers) <- JSON.decode(output),
         [env] <- Enum.filter(Inventory.from_containers(containers), &(&1.env_id == vm.env_id)),
         true <- Enum.all?(env.containers, &plausible?/1) do
      # The slug comes from the VM's own config, not from labels the guest
      # could have set.
      %{env | slug: vm.slug}
    else
      _ -> partial(vm)
    end
  end

  defp partial(vm), do: %{env_id: vm.env_id, slug: vm.slug, state: "partial", containers: []}

  # The list is the guest's to write. One bad entry would make the whole
  # box.inventory event invalid, and with it every environment's state.
  defp plausible?(%{id: id, service: service, state: state}) do
    Enum.all?([{id, 128}, {service, 255}, {state, 32}], fn {v, max} ->
      is_binary(v) and byte_size(v) <= max
    end)
  end

  @doc """
  Capacity from the host, and usage per environment: CPU time since the
  last sample and memory in use, as Incus reports them. For a VM those
  come from the agent inside it, so they're held to the VM's size.
  """
  @spec stats(map()) :: {:ok, map()} | {:error, String.t()}
  def stats(ctx) do
    with {:ok, vms} <- Incus.list(ctx) do
      {disk_mb, free_mb} = ForemanAgent.Stats.disk(ctx)
      host_cpus = :erlang.system_info(:logical_processors_available)
      host_mb = host_memory_mb()

      environments =
        vms
        |> Enum.filter(&(&1.status == :running and valid?(&1)))
        |> Task.async_stream(fn vm -> {vm, Incus.usage(ctx, vm.name)} end,
          max_concurrency: 8,
          timeout: 20_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {vm, {:ok, usage}}} ->
            now = System.monotonic_time(:nanosecond)
            cpu = min(cpu_percent(vm, usage.cpu_ns, now), (vm.cpus || host_cpus) * 100.0)
            memory = min(div(usage.memory_bytes, 1024 * 1024), vm.memory_mb || host_mb)
            [{vm.env_id, %{cpu_percent: cpu, memory_mb: memory}}]

          _ ->
            []
        end)
        |> Map.new()

      {:ok,
       %{
         capacity: %{
           cpus: host_cpus,
           memory_mb: host_mb,
           disk_mb: disk_mb,
           disk_free_mb: free_mb
         },
         environments: environments
       }}
    end
  end

  defp cpu_percent(vm, cpu_ns, now) do
    key = {__MODULE__, :cpu, vm.name}
    previous = :persistent_term.get(key, nil)
    :persistent_term.put(key, {cpu_ns, now})

    case previous do
      {ns, at} when now > at and cpu_ns >= ns ->
        Float.round((cpu_ns - ns) / (now - at) * 100, 2)

      _ ->
        0.0
    end
  end

  defp host_memory_mb do
    with {:ok, meminfo} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/^MemTotal:\s+(\d+) kB/m, meminfo) do
      div(String.to_integer(kb), 1024)
    else
      _ -> 0
    end
  end

  @doc "Prunes each running VM's Docker; stopped VMs are left alone."
  def gc(ctx) do
    with {:ok, vms} <- Incus.list(ctx) do
      for vm <- vms, vm.status == :running do
        for args <- [
              ["image", "prune", "--force"],
              ["builder", "prune", "--force", "--filter", "until=168h"],
              ["volume", "prune", "--force"]
            ] do
          ctx.log.("info", "#{vm.slug}: docker #{Enum.join(args, " ")}\n")

          Incus.exec(ctx, vm.name, ["docker" | args],
            on_output: &ctx.log.("stdout", &1),
            timeout: :timer.minutes(30)
          )
        end
      end

      {:ok, %{}}
    end
  end
end
