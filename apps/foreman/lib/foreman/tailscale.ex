defmodule Foreman.Tailscale do
  @moduledoc """
  Tailnet membership for environments.

  Each new environment gets a single-use, pre-authorized auth key tagged
  `tag:foreman-env`, plus any configured tags, the repo's tags, and
  `tag:foreman-<login>` on team deployments so ACLs can keep developers
  to their own environments. The node's state lives in a volume, so the
  key is only needed on the first boot.

  The agent reports the node each environment joined as, and destroying
  the environment deletes that device. Matching on hostname alone isn't
  enough: two deployments sharing a tailnet can both have a `storefront-1`.
  A periodic job retries deletes that didn't happen. Only with a
  deployment tag (`FOREMAN_TAILSCALE_DEPLOYMENT_TAG`) does Foreman delete
  devices it has no record of, and then only ones carrying that tag.
  Every delete needs `tag:foreman-env`, the environment's hostname and
  any deployment tag: recorded IDs come from inside the repo's container.
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

  @doc """
  The tag that marks this deployment's nodes on a tailnet other
  deployments share (`FOREMAN_TAILSCALE_DEPLOYMENT_TAG`), or nil.
  """
  def deployment_tag do
    case Application.get_env(:foreman, :tailscale, %{})[:deployment_tag] do
      tag when is_binary(tag) and tag != "" -> tag
      _ -> nil
    end
  end

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

    Enum.uniq(
      [@marker | base_tags()] ++ repo.tailscale_tags ++ team ++ List.wrap(deployment_tag())
    )
  end

  @doc """
  The tags a box's own node gets (`FOREMAN_TAILSCALE_BOX_TAGS`), by
  default `tag:foreman-box`. Never the environments' marker tag or the
  deployment tag: cleanup deletes devices with those.
  """
  def box_tags do
    case Application.get_env(:foreman, :tailscale, %{})[:box_tags] do
      [_ | _] = tags -> tags
      _ -> ["tag:foreman-box"]
    end
  end

  @doc """
  A single-use, pre-authorized key for a Flatcar box to join the tailnet
  with, expiring after `expiry_seconds` (its join token's lifetime: the
  box has to boot before the token expires anyway).
  """
  def create_box_auth_key(box_name, expiry_seconds) do
    case creds() do
      nil ->
        {:error, :not_configured}

      creds ->
        Client.impl().create_auth_key(creds, %{
          tags: box_tags(),
          description: "foreman box #{box_name}",
          expiry_seconds: expiry_seconds
        })
    end
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
  Deletes the device an environment joined as. The ID came from inside
  the repo's container, so the device must also be Foreman's and carry
  the environment's hostname. With `replaced_by` (the environment came
  back as a new node), the new device gets the bare `slug` name, which
  Tailscale gave it a suffix for while the old one was around.
  """
  def delete_device(slug, device_id, replaced_by \\ nil) do
    with creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      old = Enum.filter(devices, &(device_id?(&1, device_id) and ours?(&1, slug)))

      with :ok <- delete_all(old, creds),
           do:
             rename(replaced_by && Enum.find(devices, &device_id?(&1, replaced_by)), slug, creds)
    else
      nil -> :ok
      error -> error
    end
  end

  @doc """
  Deletes this deployment's devices named after `slug`, for an
  environment whose device was never recorded. Needs a deployment tag:
  without one, another deployment's device could have the same name.
  Does nothing if a live environment has taken the slug since: a retried
  job can run long after the destroy.
  """
  def delete_devices_for(slug) do
    with true <- deployment_tag() != nil,
         creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      if slug in Foreman.Environments.live_slugs() do
        :ok
      else
        devices
        |> Enum.filter(&ours?(&1, slug))
        |> delete_all(creds)
      end
    else
      false -> :ok
      nil -> :ok
      error -> error
    end
  end

  @doc """
  Deletes the recorded devices of destroyed environments that are still
  on the tailnet, and with a deployment tag, this deployment's devices
  that don't belong to a live environment. Tagged devices count against
  the plan, so stale ones cost.
  """
  def cleanup do
    with creds when not is_nil(creds) <- creds(),
         {:ok, devices} <- Client.impl().list_devices(creds) do
      recorded = Foreman.Environments.recorded_devices()
      live_ids = for {id, _slug, true} <- recorded, into: MapSet.new(), do: id
      live_slugs = Foreman.Environments.live_slugs()
      live? = fn device -> Enum.any?(live_ids, &device_id?(device, &1)) end

      destroyed =
        for {id, slug, false} <- recorded,
            device <- devices,
            device_id?(device, id) and ours?(device, slug),
            do: device

      untracked =
        case deployment_tag() do
          nil ->
            []

          tag ->
            Enum.filter(devices, fn device ->
              foreman_device?(device) and tag in tags(device) and
                hostname(device) not in live_slugs
            end)
        end

      stale = (destroyed ++ untracked) |> Enum.reject(live?) |> Enum.uniq_by(& &1["id"])

      with :ok <- delete_all(stale, creds), do: {:ok, length(stale)}
    else
      nil -> {:ok, 0}
      error -> error
    end
  end

  # Tailscale refuses a name another device holds, which can be an old
  # device another job is still removing, so a failure is retried.
  defp rename(nil, _slug, _creds), do: :ok

  defp rename(device, slug, creds) do
    if ours?(device, slug) and dns_label(device) != slug do
      case Client.impl().set_device_name(creds, device["id"], slug) do
        :ok ->
          Logger.info("renamed tailnet device #{device["name"]} to #{slug}")

        error ->
          Logger.warning("couldn't rename tailnet device #{device["name"]}: #{inspect(error)}")
          error
      end
    else
      :ok
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

  defp foreman_device?(device), do: @marker in tags(device)

  # With a deployment tag, a device without it is another deployment's,
  # whatever ID the environment's container reported.
  defp ours?(device, slug) do
    foreman_device?(device) and hostname(device) == slug and
      (deployment_tag() == nil or deployment_tag() in tags(device))
  end

  # The agent reports the stable node ID; the API lists it as `nodeId`
  # beside the older numeric `id`.
  defp device_id?(device, id), do: id in [device["nodeId"], device["id"]]

  defp tags(device), do: device["tags"] || []

  defp dns_label(device), do: (device["name"] || "") |> String.split(".") |> hd()

  defp hostname(device), do: device["hostname"] || dns_label(device)
end
