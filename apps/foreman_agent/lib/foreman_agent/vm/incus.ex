defmodule ForemanAgent.Vm.Incus do
  @moduledoc """
  Environment VMs through the `incus` CLI.

  incusd owns the VMs, so they keep running when the agent restarts or
  updates itself, the way dockerd owns containers today. Each VM is
  named after its environment (`name/1`) and carries the environment's id
  and slug in `user.foreman.*` config keys, which is how `list/1` finds
  them again.

  Every call goes through `ctx.runner` (so tests stub it) and runs with
  stdin closed: `incus init` and others read YAML from a stdin that isn't
  a terminal, and a runner's stdin is a pipe that never closes.
  """

  # Lost connections and slow daemons get this long per call; boots and
  # deletes of big disks get longer.
  @timeout :timer.minutes(2)
  @long_timeout :timer.minutes(10)
  @list_keep 16 * 1024 * 1024
  @state_keep 1024 * 1024
  @no_stdin ~s(exec "$0" "$@" </dev/null)

  @doc "The VM name for an environment."
  def name(env_id), do: "fm-" <> env_id

  @spec create(map(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def create(ctx, name, opts) do
    profiles = Enum.flat_map(["default" | ctx.config.vm_profiles], &["--profile", &1])

    config =
      [
        "limits.cpu=#{Keyword.fetch!(opts, :cpus)}",
        "limits.memory=#{Keyword.fetch!(opts, :memory_mb)}MiB",
        # The control plane starts environments after a reboot, once their
        # secrets are back.
        "boot.autostart=false",
        "security.secureboot=false",
        "user.foreman.env_id=#{Keyword.fetch!(opts, :env_id)}",
        "user.foreman.slug=#{Keyword.fetch!(opts, :slug)}"
      ]
      |> Enum.flat_map(&["-c", &1])

    args =
      ["init", ctx.config.vm_image, name, "--vm"] ++
        profiles ++ config ++ ["-d", "root,size=#{Keyword.fetch!(opts, :disk_gb)}GiB"]

    ok(incus(ctx, args, @long_timeout), "incus init")
  end

  @doc "A VM's state and size, or `:missing`."
  @spec info(map(), String.t()) :: {:ok, map() | :missing} | {:error, String.t()}
  def info(ctx, name) do
    case incus(ctx, ["query", "/1.0/instances/#{name}"], @timeout) do
      {:ok, %{status: 0, output: output}} ->
        case output |> json_body() |> JSON.decode() do
          {:ok, %{"status" => status} = instance} ->
            config = instance["config"] || %{}

            {:ok,
             %{
               status: status(status),
               cpus: parse_cpus(config["limits.cpu"]),
               memory_mb: parse_memory_mb(config["limits.memory"])
             }}

          _ ->
            {:error, "incus query returned #{inspect(String.slice(output, 0, 200))}"}
        end

      {:ok, %{status: status, output: output}} when is_integer(status) ->
        if output =~ "not found",
          do: {:ok, :missing},
          else: {:error, "incus query failed: #{String.trim(output)}"}

      other ->
        failure(other, "incus query")
    end
  end

  @spec state(map(), String.t()) ::
          {:ok, :running | :stopped | :other | :missing} | {:error, String.t()}
  def state(ctx, name) do
    with {:ok, info} <- info(ctx, name) do
      {:ok, if(info == :missing, do: :missing, else: info.status)}
    end
  end

  @doc """
  Foreman's VMs on this box, with each one's size. Instances come without
  their state: much of a VM's state (its network interfaces, say) is what
  the guest reports about itself, and a guest could make it big enough to
  break the listing for every VM. `usage/2` reads one VM's state.
  """
  @spec list(map()) :: {:ok, [map()]} | {:error, String.t()}
  def list(ctx) do
    with {:ok, %{status: 0, output: output}} <-
           run(ctx, ["query", "/1.0/instances?recursion=1"], timeout: @timeout, keep: @list_keep),
         {:ok, instances} when is_list(instances) <- output |> json_body() |> JSON.decode() do
      {:ok, Enum.flat_map(instances, &instance/1)}
    else
      {:ok, %{output: output}} -> {:error, "incus query failed: #{String.trim(output)}"}
      {:ok, _} -> {:error, "incus query returned something other than a list"}
      {:error, %JSON.DecodeError{}} -> {:error, "incus query returned invalid JSON"}
      other -> failure(other, "incus query")
    end
  end

  @doc """
  One VM's CPU time and memory in use. For VMs Incus takes these from the
  agent inside the guest, so they're the guest's word; callers bound them
  by the VM's size.
  """
  @spec usage(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def usage(ctx, name) do
    with {:ok, %{status: 0, output: output}} <-
           run(ctx, ["query", "/1.0/instances/#{name}/state"],
             timeout: @timeout,
             keep: @state_keep
           ),
         {:ok, %{} = state} <- output |> json_body() |> JSON.decode(),
         cpu when is_integer(cpu) and cpu >= 0 <- get_in(state, ["cpu", "usage"]) || 0,
         memory when is_integer(memory) and memory >= 0 <- get_in(state, ["memory", "usage"]) || 0 do
      {:ok, %{cpu_ns: cpu, memory_bytes: memory}}
    else
      _ -> {:error, "couldn't read the state of #{name}"}
    end
  end

  @doc "Sets a stopped VM's vCPUs and memory."
  def resize(ctx, name, cpus, memory_mb) do
    args = ["config", "set", name, "limits.cpu=#{cpus}", "limits.memory=#{memory_mb}MiB"]
    ok(incus(ctx, args, @timeout), "incus config set")
  end

  defp instance(%{"name" => name, "config" => %{"user.foreman.env_id" => env_id} = config} = i)
       when is_binary(name) and is_binary(env_id) do
    [
      %{
        name: name,
        env_id: env_id,
        slug: config["user.foreman.slug"],
        status: status(i["status"]),
        cpus: parse_cpus(config["limits.cpu"]),
        memory_mb: parse_memory_mb(config["limits.memory"])
      }
    ]
  end

  defp instance(_), do: []

  # The client prints a notice on its first run (a new HOME), and the
  # runner merges stderr into the output.
  defp json_body(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, ["[", "{"])))
    |> Enum.join("\n")
  end

  defp parse_cpus(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_cpus(_), do: nil

  @units %{
    "" => 1,
    "B" => 1,
    "kB" => 1_000,
    "MB" => 1_000_000,
    "GB" => 1_000_000_000,
    "KiB" => 1024,
    "MiB" => 1_048_576,
    "GiB" => 1_073_741_824,
    "TiB" => 1_099_511_627_776
  }

  defp parse_memory_mb(value) when is_binary(value) do
    with {n, unit} when n > 0 <- Integer.parse(value),
         {:ok, factor} <- Map.fetch(@units, unit) do
      div(n * factor, 1_048_576)
    else
      _ -> nil
    end
  end

  defp parse_memory_mb(_), do: nil

  # A guest can mark itself Ready through the guest API; that's a running VM.
  defp status(status) when status in ["Running", "Ready"], do: :running
  defp status("Stopped"), do: :stopped
  defp status(_), do: :other

  def start(ctx, name), do: ok(incus(ctx, ["start", name], @long_timeout), "incus start")

  @doc """
  Stops cleanly, and forces it when the guest doesn't shut down in time.
  `force: true` skips the clean stop (a frozen VM can't shut itself down).
  """
  def stop(ctx, name, opts \\ [])

  def stop(ctx, name, force: true),
    do: ok(incus(ctx, ["stop", name, "--force"], @long_timeout), "incus stop")

  def stop(ctx, name, _opts) do
    case incus(ctx, ["stop", name, "--timeout", "60"], @long_timeout) do
      {:ok, %{status: 0}} -> :ok
      _ -> ok(incus(ctx, ["stop", name, "--force"], @long_timeout), "incus stop")
    end
  end

  def delete(ctx, name),
    do: ok(incus(ctx, ["delete", name, "--force"], @long_timeout), "incus delete")

  @doc "Waits until the VM's agent answers, so exec works."
  @spec wait_ready(map(), String.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def wait_ready(ctx, name, timeout \\ :timer.minutes(5)) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_ready_until(ctx, name, deadline)
  end

  defp wait_ready_until(ctx, name, deadline) do
    case incus(ctx, exec_args(name, ["true"]), :timer.seconds(30)) do
      {:ok, %{status: 0}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, "the VM #{name} didn't come up"}
        else
          Process.sleep(1_000)
          wait_ready_until(ctx, name, deadline)
        end
    end
  end

  @doc "argv for `incus exec`: `:cwd`, and `:env` as a map (sorted, so it's stable)."
  def exec_args(name, argv, opts \\ []) do
    cwd = if opts[:cwd], do: ["--cwd", opts[:cwd]], else: []

    env =
      opts
      |> Keyword.get(:env, %{})
      |> Enum.sort()
      |> Enum.flat_map(fn {k, v} -> ["--env", "#{k}=#{v}"] end)

    ["exec", name] ++ cwd ++ env ++ ["--" | argv]
  end

  @doc "Runs a command in the VM through the runner, with the runner's options."
  def exec(ctx, name, argv, opts \\ []) do
    {exec_opts, run_opts} = Keyword.split(opts, [:cwd, :env])
    run(ctx, exec_args(name, argv, exec_opts), run_opts)
  end

  @spec push(map(), String.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def push(ctx, name, local, remote, opts) do
    args =
      ["file", "push", "--uid", "#{opts[:uid]}", "--gid", "#{opts[:gid]}"] ++
        ["--mode", mode(opts[:mode]), local, name <> remote]

    ok(incus(ctx, args, @long_timeout), "incus file push")
  end

  defp mode(mode), do: "0" <> Integer.to_string(mode, 8)

  @doc "Runs an incus subcommand through the runner, with stdin closed."
  def run(ctx, args, opts) do
    ctx.runner.run(
      "sh",
      ["-c", @no_stdin, ctx.config.incus | args],
      Keyword.put_new(opts, :env, %{})
    )
  end

  defp incus(ctx, args, timeout), do: run(ctx, args, timeout: timeout)

  defp ok({:ok, %{status: 0}}, _what), do: :ok
  defp ok(other, what), do: failure(other, what)

  defp failure({:ok, %{status: :timeout}}, what), do: {:error, "#{what} timed out"}

  defp failure({:ok, %{output: output}}, what),
    do: {:error, "#{what} failed: #{String.trim(output)}"}

  defp failure({:error, reason}, what), do: {:error, "#{what} failed: #{inspect(reason)}"}
end
