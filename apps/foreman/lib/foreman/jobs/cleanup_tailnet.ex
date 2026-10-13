defmodule Foreman.Jobs.CleanupTailnet do
  @moduledoc """
  Removes tailnet devices left behind by destroyed environments. With a
  `slug` arg, removes that environment's devices; without, sweeps every
  Foreman-tagged device that doesn't match a live environment.
  """
  use Oban.Worker, queue: :tailscale, max_attempts: 5

  @impl true
  def perform(%Oban.Job{args: %{"slug" => slug}}), do: Foreman.Tailscale.delete_devices_for(slug)

  def perform(_job) do
    case Foreman.Tailscale.cleanup(Foreman.Environments.live_slugs()) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
