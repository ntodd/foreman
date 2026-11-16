defmodule ForemanAgent.Restart do
  @moduledoc """
  Reboots the box for `box.restart`.

  The agent can't reboot anything itself: it runs unprivileged. The
  install script sets up a root path unit (`foreman-restart.path`) that
  watches a file in the agent's runtime directory and reboots the box a
  few seconds after it appears, which leaves the agent time to answer.
  Nothing an environment runs can write there: environments only see
  their own secrets directory below it.

  The command names the boot the control plane saw. A command resent
  after the reboot, because the agent went down before its answer got
  through, finds another boot and is done already.
  """

  alias ForemanAgent.{Config, Reboot, SafeFS}

  @spec request(Config.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def request(%Config{} = config, boot_id) do
    if File.exists?(config.restart_unit) do
      case Reboot.boot_id(config) do
        {:ok, ^boot_id} -> ask(config, boot_id)
        {:ok, _another} -> {:ok, %{"already" => true}}
        :error -> {:error, "couldn't read the box's boot id from #{config.boot_id}"}
      end
    else
      {:error, "this box can't be rebooted from Foreman yet; run the install command on it again"}
    end
  end

  defp ask(config, boot_id) do
    case SafeFS.write_atomic(config.restart_request, boot_id <> "\n", 0o644) do
      :ok -> {:ok, %{"requested" => true}}
      {:error, reason} -> {:error, "couldn't ask for the reboot: #{inspect(reason)}"}
    end
  end
end
