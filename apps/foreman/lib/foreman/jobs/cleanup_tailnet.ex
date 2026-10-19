defmodule Foreman.Jobs.CleanupTailnet do
  @moduledoc """
  Removes tailnet devices left behind by destroyed or replaced
  environments. With a `device_id` arg, removes that device (and with
  `replaced_by`, renames the node that replaced it); with only a `slug`,
  an environment whose device was never recorded, removes this
  deployment's devices with that hostname. Without either, sweeps, unless
  `FOREMAN_TAILNET_SWEEP=false`. See `Foreman.Tailscale` for what each
  one is allowed to delete.
  """
  use Oban.Worker, queue: :tailscale, max_attempts: 10

  # A minute, doubling, so the retries outlast a Tailscale outage (about
  # eight and a half hours in all). The sweep only covers destroyed
  # environments, so a replaced device has nothing else to fall back on.
  @impl true
  def backoff(%Oban.Job{attempt: attempt}), do: 30 * Integer.pow(2, attempt)

  @impl true
  def perform(%Oban.Job{args: %{"slug" => slug, "device_id" => id} = args}),
    do: Foreman.Tailscale.delete_device(slug, id, args["replaced_by"])

  def perform(%Oban.Job{args: %{"slug" => slug}}), do: Foreman.Tailscale.delete_devices_for(slug)

  def perform(_job) do
    if Application.get_env(:foreman, :tailnet_sweep, true) do
      case Foreman.Tailscale.cleanup() do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end
end
