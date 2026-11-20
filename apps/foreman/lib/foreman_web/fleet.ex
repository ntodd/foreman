defmodule ForemanWeb.Fleet do
  @moduledoc """
  The fleet at a glance, from the box cards a page already holds (each
  `%{box, online, summary, count}`): what the online boxes offer and
  hold, and what's wrong with any box that needs a look. Nothing here
  reads the database, so a page can recompute it on every box.stats.
  """

  alias Foreman.Boxes

  @doc """
  Totals over `cards`. Capacity, what's provisioned and what's in use
  count the online boxes only: an offline box offers nothing.
  """
  def totals(cards) do
    online = Enum.filter(cards, & &1.online)
    reporting = Enum.filter(online, & &1.summary.reported_at)
    disks = for %{summary: %{disk_free_mb: free}} <- online, is_number(free), do: free

    %{
      boxes: length(cards),
      online: length(online),
      attention: Enum.count(cards, &(issues(&1) != [])),
      reporting: length(reporting),
      environments: Enum.sum_by(cards, & &1.count),
      cpus: Enum.sum_by(online, & &1.summary.cpus),
      memory_mb: Enum.sum_by(online, & &1.summary.memory_mb),
      provisioned_cpus: Enum.sum_by(online, & &1.summary.provisioned_cpus),
      provisioned_memory_mb: Enum.sum_by(online, & &1.summary.provisioned_memory_mb),
      used_cpus: Enum.sum_by(reporting, & &1.summary.used_cpus),
      used_memory_mb: Enum.sum_by(reporting, & &1.summary.used_memory_mb),
      disk_free_mb: if(disks != [], do: Enum.sum(disks))
    }
  end

  @doc """
  What's wrong with a box, worst first, each `%{role, label, level}`:
  `role` matches the `data-role` of the badge the box's card shows for
  it, and `level` is `:danger` or `:warning`.
  """
  def issues(%{box: box, online: online, summary: summary}) do
    Enum.reject(
      [
        not online && issue("offline", "Offline", :danger),
        vm_issue(Boxes.vm_problem(box)),
        firewall_issue(Boxes.firewall_problem(box)),
        Boxes.reboot_needed(box) && issue("reboot-alert", "Reboot required", :warning),
        summary.contention && issue("contention", "Contention", :warning)
      ],
      &(&1 in [nil, false])
    )
  end

  defp vm_issue({:agent, _}), do: issue("vm-alert", "Agent too old", :danger)
  defp vm_issue({:vm, _}), do: issue("vm-alert", "Can't run environments", :danger)
  defp vm_issue(nil), do: nil

  defp firewall_issue(:missing), do: issue("firewall-alert", "Firewall unconfirmed", :danger)
  defp firewall_issue(:outdated), do: issue("firewall-alert", "Firewall rules differ", :warning)
  defp firewall_issue(_), do: nil

  defp issue(role, label, level), do: %{role: role, label: label, level: level}

  @doc "A share of `total` as a whole percentage, or nil when there's no total."
  def percent(_part, total) when total <= 0, do: nil
  def percent(part, total), do: round(100 * part / total)

  @doc "A count of cores: whole when it is, to one decimal when it isn't."
  def cores(n) when is_integer(n), do: Integer.to_string(n)

  def cores(n) when is_float(n) do
    if Float.round(n, 1) == Float.round(n, 0),
      do: Integer.to_string(round(n)),
      else: :erlang.float_to_binary(n, decimals: 1)
  end
end
