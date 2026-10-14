defmodule Foreman.Tailscale do
  @moduledoc """
  Tailnet membership for environments.

  Each new environment gets a single-use, pre-authorized auth key tagged
  `tag:foreman-env` (or the configured tags), plus the repo's tags, plus
  `tag:foreman-<login>` on team deployments so ACLs can keep developers
  to their own environments. The node's state lives in a volume, so the
  key is only needed on the first boot. Destroyed environments' devices
  are deleted, and a periodic job removes any that are left over.
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

  def base_tags do
    case Application.get_env(:foreman, :tailscale, %{})[:tags] do
      tags when is_list(tags) and tags != [] -> tags
      _ -> ["tag:foreman-env"]
    end
  end

  @doc "The tags an environment's node gets."
  def tags_for(repo, user) do
    team =
      if Application.get_env(:foreman, :slug_style) == :team,
        do: ["tag:foreman-" <> String.downcase(user.login)],
        else: []

    Enum.uniq(base_tags() ++ repo.tailscale_tags ++ team)
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

  @doc "Deletes the tailnet devices named after `slug`."
  def delete_devices_for(slug) do
    with creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      for device <- devices, hostname(device) == slug do
        Client.impl().delete_device(creds, device["id"])
      end

      :ok
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
    tags = MapSet.new(base_tags())

    with creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      stale =
        Enum.filter(devices, fn d ->
          Enum.any?(d["tags"] || [], &MapSet.member?(tags, &1)) and hostname(d) not in live_slugs
        end)

      for device <- stale do
        Logger.info("removing stale tailnet device #{hostname(device)}")
        Client.impl().delete_device(creds, device["id"])
      end

      {:ok, length(stale)}
    else
      nil -> {:ok, 0}
      error -> error
    end
  end

  defp hostname(device),
    do: device["hostname"] || (device["name"] || "") |> String.split(".") |> hd()
end
