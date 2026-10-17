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

  @spec state(map(), String.t()) :: {:ok, :running | :stopped | :missing} | {:error, String.t()}
  def state(ctx, name) do
    case incus(ctx, ["query", "/1.0/instances/#{name}"], @timeout) do
      {:ok, %{status: 0, output: output}} ->
        case output |> json_body() |> JSON.decode() do
          {:ok, %{"status" => status}} -> {:ok, status(status)}
          _ -> {:error, "incus query returned #{inspect(String.slice(output, 0, 200))}"}
        end

      {:ok, %{status: status, output: output}} when is_integer(status) ->
        if output =~ "not found",
          do: {:ok, :missing},
          else: {:error, "incus query failed: #{String.trim(output)}"}

      other ->
        failure(other, "incus query")
    end
  end

  @doc "Foreman's VMs on this box, with each one's CPU time and memory."
  @spec list(map()) :: {:ok, [map()]} | {:error, String.t()}
  def list(ctx) do
    with {:ok, %{status: 0, output: output}} <- incus(ctx, ["list", "--format", "json"], @timeout),
         {:ok, instances} when is_list(instances) <- output |> json_body() |> JSON.decode() do
      {:ok, Enum.flat_map(instances, &instance/1)}
    else
      {:ok, %{output: output}} -> {:error, "incus list failed: #{String.trim(output)}"}
      {:ok, _} -> {:error, "incus list returned something other than a list"}
      {:error, %JSON.DecodeError{}} -> {:error, "incus list returned invalid JSON"}
      other -> failure(other, "incus list")
    end
  end

  # The client prints a notice on its first run (a new HOME), and the
  # runner merges stderr into the output.
  defp json_body(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, ["[", "{"])))
    |> Enum.join("\n")
  end

  defp instance(%{"name" => name, "config" => %{"user.foreman.env_id" => env_id} = config} = i)
       when is_binary(name) and is_binary(env_id) do
    state = i["state"] || %{}

    [
      %{
        name: name,
        env_id: env_id,
        slug: config["user.foreman.slug"],
        status: status(i["status"]),
        cpu_ns: get_in(state, ["cpu", "usage"]) || 0,
        memory_bytes: get_in(state, ["memory", "usage"]) || 0
      }
    ]
  end

  defp instance(_), do: []

  defp status("Running"), do: :running
  defp status("Stopped"), do: :stopped
  defp status(_), do: :other

  def start(ctx, name), do: ok(incus(ctx, ["start", name], @long_timeout), "incus start")

  @doc "Stops cleanly, and forces it when the guest doesn't shut down in time."
  def stop(ctx, name) do
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
