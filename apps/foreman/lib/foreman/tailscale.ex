defmodule Foreman.Tailscale do
  @moduledoc """
  Tailnet membership for environments.

  Each new environment gets a single-use, pre-authorized auth key tagged
  `tag:foreman-env`, plus any configured tags, the repo's tags, and
  `tag:foreman-<login>` on team deployments so ACLs can keep developers
  to their own environments. The node's state lives in a volume, so the
  key is only needed on the first boot. Destroyed environments' devices
  are deleted, and a periodic job removes any that are left over. Both
  only ever delete devices tagged `tag:foreman-env`.
  """

  alias Foreman.Tailscale.Client

  require Logger

  @key_expiry 24 * 3600

  def creds do
    config = Application.get_env(:foreman, :tailscale, %{})

    if is_binary(config[:client_id]) and config[:client_id] != "" and
         is_binary(config[:client_secret]),
       do: %{
         client_id: config.client_id,
         client_secret: config.client_secret,
         tailnet: config[:tailnet] || "-"
       },
       else: nil
  end

  def configured?, do: creds() != nil

  @marker "tag:foreman-env"

  @doc """
  The tag every environment node carries. Cleanup only deletes devices
  with this tag, so it can't touch laptops or CI runners that share one
  of the other configured tags.
  """
  def marker_tag, do: @marker

  @doc "Extra tags every environment gets (`FOREMAN_TAILSCALE_TAGS`)."
  def base_tags do
    case Application.get_env(:foreman, :tailscale, %{})[:tags] do
      tags when is_list(tags) -> tags
      _ -> []
    end
  end

  @doc "The tags an environment's node gets."
  def tags_for(repo, user) do
    team =
      if Application.get_env(:foreman, :slug_style) == :team,
        do: ["tag:foreman-" <> String.downcase(user.login)],
        else: []

    Enum.uniq([@marker | base_tags()] ++ repo.tailscale_tags ++ team)
  end

  def create_auth_key(env, repo, user) do
    case creds() do
      nil ->
        {:error, :not_configured}

      creds ->
        Client.impl().create_auth_key(creds, %{
          tags: tags_for(repo, user),
          description: "foreman #{env.slug}",
          expiry_seconds: @key_expiry
        })
    end
  end

  @doc """
  Deletes the Foreman-tagged devices named after `slug`. Does nothing if
  a live environment has taken the slug since: a retried job can run
  long after the destroy.
  """
  def delete_devices_for(slug) do
    with creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      if slug in Foreman.Environments.live_slugs() do
        :ok
      else
        devices
        |> Enum.filter(&(foreman_device?(&1) and hostname(&1) == slug))
        |> delete_all(creds)
      end
    else
      nil -> :ok
      error -> error
    end
  end

  @doc """
  Deletes Foreman-tagged devices whose hostname doesn't belong to a live
  environment. Tagged devices count against the plan, so stale ones cost.
  """
  def cleanup(live_slugs) do
    with creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      stale = Enum.filter(devices, &(foreman_device?(&1) and hostname(&1) not in live_slugs))

      with :ok <- delete_all(stale, creds), do: {:ok, length(stale)}
    else
      nil -> {:ok, 0}
      error -> error
    end
  end

  # Tries every device, then returns the first failure so the job retries.
  defp delete_all(devices, creds) do
    devices
    |> Enum.map(fn device ->
      Logger.info("removing stale tailnet device #{hostname(device)}")

      case Client.impl().delete_device(creds, device["id"]) do
        :ok ->
          :ok

        error ->
          Logger.warning("couldn't remove tailnet device #{hostname(device)}: #{inspect(error)}")
          error
      end
    end)
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp foreman_device?(device), do: @marker in (device["tags"] || [])

  defp hostname(device),
    do: device["hostname"] || (device["name"] || "") |> String.split(".") |> hd()
end
