defmodule Foreman.Capacity do
  @moduledoc """
  Capacity reporting. Foreman never assumes a box has room: by default it
  reports contention and lets you decide.

  An environment's *provisioned* size is the first of:

  1. on a box that runs each environment in its own VM, the VM's size
     (the one recorded when it was made, else the one it'll be sent)
  2. its limits (or its repo's default limits)
  3. its repo's `hostRequirements`
  4. its observed usage, averaged over about 15 minutes

  A box is in contention when what's provisioned (or what's observed)
  passes its threshold of capacity. Placement past that is allowed by
  default; a box can be set to warn or refuse.
  """

  alias Foreman.Boxes.Box
  alias Foreman.Capacity.Tracker
  alias Foreman.Environments.Environment

  @doc """
  Provisioned CPUs and memory (MB) for an environment, and where the
  numbers came from. Whether it's on a VM box comes from `env.box`.
  """
  def provisioned(%Environment{} = env, repo) do
    reqs = env.host_requirements || repo.host_requirements

    from_vm(env, repo) || from_limits(env, repo, reqs) || from_requirements(reqs) ||
      from_observed(env.id) || %{cpus: 0, memory_mb: 0, source: :unknown}
  end

  # A VM holds its whole size while it runs, however little it uses.
  defp from_vm(%Environment{vm: %{"cpus" => cpus, "memory_mb" => mb}}, _repo),
    do: %{cpus: cpus, memory_mb: mb, source: :vm}

  defp from_vm(%Environment{box: %Box{isolation: "vm"}} = env, repo),
    do: env |> vm_size(repo) |> Map.put(:source, :vm)

  defp from_vm(_env, _repo), do: nil

  @doc """
  The size of the VM an environment on a VM box is made with: its
  limits, else its repo's, else the repo's hostRequirements, else the
  deployment's default, for CPUs and memory separately. CPUs round up to
  whole vCPUs.
  """
  def vm_size(%Environment{} = env, repo) do
    reqs = env.host_requirements || repo.host_requirements
    default = Foreman.Config.vm_default_size()

    cpus = env.cpu_limit || repo.cpu_limit || positive(req_cpus(reqs)) || default.cpus

    memory_mb =
      env.memory_limit_mb || repo.memory_limit_mb || positive(req_memory(reqs)) ||
        default.memory_mb

    %{cpus: ceil(cpus), memory_mb: memory_mb}
  end

  defp positive(n) when is_number(n) and n > 0, do: n
  defp positive(_), do: nil

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
  def req_cpus(%{"cpus" => cpus}) when is_number(cpus), do: cpus
  def req_cpus(_), do: nil

  @doc ~s|hostRequirements.memory ("8gb", "512mb") in MB.|
  def req_memory(%{"memory" => memory}) when is_binary(memory), do: parse_size(memory)
  def req_memory(_), do: nil

  def parse_size(value) do
    case Regex.run(~r/\A\s*(\d+(?:\.\d+)?)\s*(tb|gb|mb|kb)?\s*\z/i, value) do
      [_, n, unit] -> round(String.to_float(normalize(n)) * multiplier(String.downcase(unit)))
      [_, n] -> round(String.to_float(normalize(n)) / (1024 * 1024))
      _ -> nil
    end
  end

  defp normalize(n), do: if(String.contains?(n, "."), do: n, else: n <> ".0")
  defp multiplier("tb"), do: 1024 * 1024
  defp multiplier("gb"), do: 1024
  defp multiplier("mb"), do: 1
  defp multiplier("kb"), do: 1 / 1024

  @doc """
  A box's capacity, what's provisioned on it, what's in use, and whether
  either passes its contention threshold. `envs` are its live
  environments (with :repo preloaded).
  """
  def box_summary(%Box{} = box, envs) do
    cap = box.capacity || %{}
    cpus = cap["cpus"] || 0
    mem = cap["memory_mb"] || 0

    running =
      Enum.filter(envs, &(&1.observed_state in ["running", "partial", "starting", "creating"]))

    # The box as given, whether or not each environment has it loaded.
    provisioned = Enum.map(running, &{&1, provisioned(%{&1 | box: box}, &1.repo)})
    latest = Tracker.latest(box.id)

    used_cpus =
      if latest,
        do: latest.environments |> Map.values() |> Enum.sum_by(& &1.cpu_percent) |> Kernel./(100),
        else: 0

    used_mem =
      if latest, do: latest.environments |> Map.values() |> Enum.sum_by(& &1.memory_mb), else: 0

    prov_cpus = Enum.sum_by(provisioned, fn {_, p} -> p.cpus end)
    prov_mem = Enum.sum_by(provisioned, fn {_, p} -> p.memory_mb end)
    threshold = box.contention_threshold || 0.9

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
        cpus > 0 and mem > 0 and
          (max(prov_cpus, used_cpus) > cpus * threshold or
             max(prov_mem, used_mem) > mem * threshold),
      reported_at: latest && latest.at
    }
  end

  @doc """
  Whether a new environment of `repo` (with optional limits) fits on the
  box, under the box's policy: `:ok`, `{:warn, message}` or
  `{:refuse, message}`.
  """
  def check_placement(%Box{} = box, envs, repo, limits \\ %{}) do
    summary = box_summary(box, envs)

    env = %Environment{
      id: "new",
      box: box,
      cpu_limit: limits[:cpu_limit],
      memory_limit_mb: limits[:memory_limit_mb]
    }

    want = provisioned(env, repo)
    threshold = box.contention_threshold || 0.9

    message =
      short_of_requirements(box, summary, repo) || over_threshold(box, summary, want, threshold)

    case {message, box.capacity_policy} do
      {nil, _} -> :ok
      {msg, "refuse"} -> {:refuse, msg}
      {msg, "warn"} -> {:warn, msg}
      {msg, _allow} -> {:contention, msg}
    end
  end

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

  defp over_threshold(box, summary, want, threshold) do
    over =
      summary.cpus > 0 and
        (summary.provisioned_cpus + want.cpus > summary.cpus * threshold or
           summary.provisioned_memory_mb + want.memory_mb > summary.memory_mb * threshold)

    if over,
      do: "#{box.name} is past #{round(threshold * 100)}% of its capacity with this environment"
  end
end
