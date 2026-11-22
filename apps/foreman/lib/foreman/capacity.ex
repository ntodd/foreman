defmodule Foreman.Capacity do
  @moduledoc """
  Capacity reporting. Foreman never assumes a box has room: by default it
  reports contention and lets you decide.

  A running or suspended VM reports its boot allocation. Cold boots resolve
  CPU and RAM independently from environment limits, repo limits and the
  box's defaults. Older agents use the legacy requirements/usage estimate.

  A box has a threshold for CPU and one for memory, as fractions of its
  capacity, and either can be past 1 to overcommit. A box is in
  contention when what's provisioned passes a resource's threshold, or
  what's in use passes it or 90%, whichever is lower: use can't pass
  capacity, so a busy box still shows when it's overcommitted. Placement
  past a threshold is allowed by default; a box can be set to warn or
  refuse.
  """

  alias Foreman.Boxes.Box
  alias Foreman.Capacity.Tracker
  alias Foreman.Environments.Environment

  @busy 0.9

  @doc "The threshold usage is held to: the box's threshold, or 90% if that's lower."
  def used_threshold(threshold), do: min(threshold, @busy)

  @doc "Provisioned CPUs and memory (MB) for an environment, and where the numbers came from."
  def provisioned(%Environment{} = env, repo) do
    provisioned(env, repo, env.box)
  end

  defp provisioned(%{vm_size: %{"cpus" => cpus, "memory_mb" => mb}}, _repo, %Box{
         vm: %{"default_cpus" => _}
       }),
       do: %{cpus: cpus, memory_mb: mb, source: :booted}

  defp provisioned(env, repo, box), do: cold_size(env, repo, box)

  defp cold_size(env, repo, %Box{
         vm: %{
           "default_cpus" => default_cpus,
           "default_memory_mb" => default_memory,
           "host_cpus" => host_cpus,
           "host_memory_mb" => host_memory
         }
       }) do
    limits = %{
      cpus: env.cpu_limit || repo.cpu_limit,
      memory_mb: env.memory_limit_mb || repo.memory_limit_mb
    }

    ForemanProtocol.VMSize.resolve(limits, %{cpus: default_cpus, memory_mb: default_memory}, %{
      cpus: host_cpus,
      memory_mb: host_memory
    })
    |> Map.put(:source, :configured)
  end

  defp cold_size(env, repo, _box) do
    reqs = env.host_requirements || repo.host_requirements

    from_limits(env, repo, reqs) || from_requirements(reqs) || from_observed(env.id) ||
      %{cpus: 0, memory_mb: 0, source: :unknown}
  end

  defp from_limits(env, repo, reqs) do
    cpus = env.cpu_limit || repo.cpu_limit
    mem = env.memory_limit_mb || repo.memory_limit_mb

    if cpus || mem,
      do: %{
        cpus: cpus || req_cpus(reqs) || 0,
        memory_mb: mem || req_memory(reqs) || 0,
        source: :limits
      }
  end

  defp from_requirements(reqs) do
    cpus = req_cpus(reqs)
    mem = req_memory(reqs)
    if cpus || mem, do: %{cpus: cpus || 0, memory_mb: mem || 0, source: :host_requirements}
  end

  defp from_observed(env_id) do
    if avg = Tracker.average(env_id),
      do: %{cpus: avg.cpu_percent / 100, memory_mb: avg.memory_mb, source: :observed}
  end

  @doc "hostRequirements.cpus as a number."
  def req_cpus(%{"cpus" => cpus}) when is_number(cpus) and cpus > 0 and cpus <= 1_000_000,
    do: cpus

  def req_cpus(_), do: nil

  @doc ~s|hostRequirements.memory ("8gb", "512mb") in MB.|
  def req_memory(%{"memory" => memory}) when is_binary(memory), do: parse_size(memory)
  def req_memory(_), do: nil

  def req_memory_label(%{"memory" => memory} = reqs) do
    if req_memory(reqs), do: memory
  end

  def req_memory_label(_), do: nil

  def parse_size(value) when is_binary(value) and byte_size(value) <= 64 do
    case Regex.run(~r/\A\s*(\d+(?:\.\d+)?)\s*(tb|gb|mb|kb)?\s*\z/i, value) do
      [_, n, unit] -> round(String.to_float(normalize(n)) * multiplier(String.downcase(unit)))
      [_, n] -> round(String.to_float(normalize(n)) / (1024 * 1024))
      _ -> nil
    end
  end

  def parse_size(_), do: nil

  defp normalize(n), do: if(String.contains?(n, "."), do: n, else: n <> ".0")
  defp multiplier("tb"), do: 1024 * 1024
  defp multiplier("gb"), do: 1024
  defp multiplier("mb"), do: 1
  defp multiplier("kb"), do: 1 / 1024

  @doc """
  A box's capacity, what's provisioned on it, what's in use, and whether
  either passes its contention thresholds. `envs` are its live
  environments (with :repo preloaded).
  """
  def box_summary(%Box{} = box, envs) do
    cap = box.capacity || %{}
    cpus = cap["cpus"] || (box.vm || %{})["host_cpus"] || 0
    mem = cap["memory_mb"] || (box.vm || %{})["host_memory_mb"] || 0

    running = Enum.filter(envs, &allocated?/1)

    provisioned = Enum.map(running, &{&1, provisioned(&1, &1.repo, box)})
    latest = Tracker.latest(box.id)

    used_cpus =
      if latest,
        do: latest.environments |> Map.values() |> Enum.sum_by(& &1.cpu_percent) |> Kernel./(100),
        else: 0

    used_mem =
      if latest, do: latest.environments |> Map.values() |> Enum.sum_by(& &1.memory_mb), else: 0

    prov_cpus = Enum.sum_by(provisioned, fn {_, p} -> p.cpus end)
    prov_mem = Enum.sum_by(provisioned, fn {_, p} -> p.memory_mb end)
    %{cpus: cpu_t, memory_mb: mem_t} = thresholds(box)

    %{
      cpus: cpus,
      memory_mb: mem,
      disk_mb: cap["disk_mb"],
      disk_free_mb: cap["disk_free_mb"],
      provisioned_cpus: prov_cpus,
      provisioned_memory_mb: prov_mem,
      used_cpus: used_cpus,
      used_memory_mb: used_mem,
      environments: provisioned,
      contention:
        past?(prov_cpus, used_cpus, cpus, cpu_t) or past?(prov_mem, used_mem, mem, mem_t),
      reported_at: latest && latest.at
    }
  end

  @doc "Whether this environment already counts toward its box's provisioned capacity."

  def allocated?(%{observed_state: state})
      when state in ~w(running partial starting creating pending), do: true

  def allocated?(%{desired_state: "running", observed_state: state})
      when state in ~w(stopped suspended missing), do: true

  def allocated?(%{vm_size: size, observed_state: state}),
    do: is_map(size) and state != "suspended"

  defp thresholds(%Box{} = box),
    do: %{cpus: box.cpu_threshold || 0.9, memory_mb: box.memory_threshold || 0.9}

  defp past?(provisioned, used, capacity, threshold),
    do:
      capacity > 0 and
        (provisioned > capacity * threshold or used > capacity * used_threshold(threshold))

  @doc """
  Whether a new environment of `repo` (with optional limits) fits on the
  box, under the box's policy: `:ok`, `{:warn, message}` or
  `{:refuse, message}`.
  """
  def check_placement(%Box{} = box, envs, repo, limits \\ %{}) do
    env = %Environment{
      id: "new",
      cpu_limit: limits[:cpu_limit],
      memory_limit_mb: limits[:memory_limit_mb]
    }

    placement(box, envs, repo, cold_size(env, repo, box))
  end

  def check_start(env, envs) do
    placement(
      env.box,
      Enum.reject(envs, &(&1.id == env.id)),
      env.repo,
      provisioned(env, env.repo)
    )
  end

  def check_resize(env, resized, envs) do
    current = cold_size(env, env.repo, env.box)
    want = cold_size(resized, env.repo, env.box)

    if want.cpus > current.cpus or want.memory_mb > current.memory_mb do
      placement(env.box, Enum.reject(envs, &(&1.id == env.id)), env.repo, want)
    else
      :ok
    end
  end

  defp placement(box, envs, repo, want) do
    summary = box_summary(box, envs)

    requirement = short_of_requirements(box, summary, repo)
    threshold = over_threshold(box, summary, want)

    if want.source in [:configured, :booted] do
      # Requirements describe the repo's preferred host. Only the VM's
      # allocation can make a placement exceed the box's threshold.
      if threshold,
        do: apply_policy(threshold, box.capacity_policy),
        else: apply_policy(requirement, "allow")
    else
      apply_policy(requirement || threshold, box.capacity_policy)
    end
  end

  defp apply_policy(nil, _policy), do: :ok
  defp apply_policy(message, "refuse"), do: {:refuse, message}
  defp apply_policy(message, "warn"), do: {:warn, message}
  defp apply_policy(message, _policy), do: {:contention, message}

  defp short_of_requirements(box, summary, repo) do
    cpus = req_cpus(repo.host_requirements)
    mem = req_memory(repo.host_requirements)

    cond do
      cpus && summary.cpus > 0 && cpus > summary.cpus ->
        "#{repo.full_name} asks for #{cpus} CPUs; #{box.name} has #{summary.cpus}"

      mem && summary.memory_mb > 0 && mem > summary.memory_mb ->
        "#{repo.full_name} asks for #{mem} MB; #{box.name} has #{summary.memory_mb}"

      true ->
        nil
    end
  end

  defp over_threshold(box, summary, want) do
    t = thresholds(box)

    over =
      [
        {"CPUs", summary.cpus, summary.provisioned_cpus + want.cpus, t.cpus},
        {"memory", summary.memory_mb, summary.provisioned_memory_mb + want.memory_mb, t.memory_mb}
      ]
      |> Enum.filter(fn {_, capacity, total, threshold} ->
        capacity > 0 and total > capacity * threshold
      end)
      |> Enum.map(fn {name, _, _, threshold} -> "#{round(threshold * 100)}% of its #{name}" end)

    if over != [],
      do: "#{box.name} is past #{Enum.join(over, " and ")} with this environment"
  end
end
