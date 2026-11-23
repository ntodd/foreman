defmodule Foreman.OAuth.DeviceFlow do
  @moduledoc "Single-use device authorizations, signed-in decisions and paced polling."
  import Ecto.Query
  alias Foreman.{Accounts, Audit, Config, OAuth, Repo}
  alias Foreman.Accounts.User
  alias Foreman.OAuth.{Client, Device, Grant, Scopes, Store}

  @lifetime 600
  @alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  def start(%Client{kind: "public"} = client, scope) do
    with {:ok, scopes} <- Store.requested_scopes(scope, Scopes.all()) do
      device_code = Store.random_secret()

      user_code =
        for <<index::5 <- :crypto.strong_rand_bytes(5)>>,
          into: "",
          do: binary_part(@alphabet, index, 1)

      <<left::binary-size(4), right::binary>> = user_code
      display_code = left <> "-" <> right
      verification_uri = Config.base_url() <> "/oauth/device"

      device =
        Repo.insert!(%Device{
          client_id: client.id,
          scopes: scopes,
          device_hash: Store.digest(device_code),
          user_code_hash: Store.digest(user_code),
          expires_at: DateTime.add(DateTime.utc_now(), @lifetime)
        })

      {:ok,
       %{
         device_code: device_code,
         user_code: display_code,
         verification_uri: verification_uri,
         verification_uri_complete: verification_uri <> "?user_code=" <> display_code,
         interval: device.interval,
         expires_in: @lifetime
       }}
    end
  end

  def start(_, _), do: {:error, :unauthorized_client}

  def lookup(code) when is_binary(code) and byte_size(code) <= 16 do
    normalized = code |> String.replace("-", "") |> String.upcase()

    query =
      from d in Device,
        join: c in assoc(d, :client),
        preload: [client: c],
        where:
          d.user_code_hash == ^Store.digest(normalized) and d.state == "pending" and
            d.expires_at > ^DateTime.utc_now() and is_nil(c.disabled_at)

    Repo.one(query)
  end

  def lookup(_), do: nil

  def decide(code, decision, user, session) when decision in ["approve", "deny"] do
    Repo.transact(fn ->
      # Serialize approval with offboarding, then recheck the browser session inside that lock.
      with %User{disabled_at: nil, service_account: false} <-
             Store.locked(from u in User, where: u.id == ^user.id),
           %User{id: id} when id == user.id <- Accounts.get_user_by_session(session),
           %Device{} = device <- lookup(code),
           {1, _} <-
             Repo.update_all(
               from(d in Device, where: d.id == ^device.id and d.state == "pending"),
               set: [state: decision]
             ) do
        if decision == "approve" do
          grant =
            Repo.insert!(%Grant{
              user_id: user.id,
              client_id: device.client_id,
              scopes: device.scopes,
              expires_at: device.expires_at
            })

          Repo.update!(Ecto.Changeset.change(device, grant_id: grant.id))
        end

        Audit.log(user, "oauth.device." <> decision, device, %{
          "client_id" => device.client_id,
          "scopes" => device.scopes
        })

        {:ok, decision}
      else
        _ -> {:error, :invalid_grant}
      end
    end)
  end

  def decide(_, _, _, _), do: {:error, :invalid_request}

  def poll(%Client{kind: "public", id: client_id}, raw) when is_binary(raw) do
    {:ok, result} =
      Repo.transact(fn ->
        device =
          Store.locked(
            from d in Device,
              where: d.device_hash == ^Store.digest(raw) and d.client_id == ^client_id
          )

        {:ok, poll_device(device, DateTime.utc_now())}
      end)

    result
  end

  def poll(_, _), do: {:error, :invalid_grant}

  defp poll_device(nil, _), do: {:error, :invalid_grant}

  defp poll_device(device, now) do
    cond do
      not DateTime.after?(device.expires_at, now) ->
        {:error, :expired_token}

      device.state == "deny" ->
        {:error, :access_denied}

      device.state == "spent" ->
        {:error, :invalid_grant}

      device.poll_after && DateTime.after?(device.poll_after, now) ->
        delay_poll(device, now, device.interval + 5, :slow_down)

      device.state == "pending" ->
        delay_poll(device, now, device.interval, :authorization_pending)

      device.state == "approve" ->
        exchange(device)
    end
  end

  defp delay_poll(device, now, interval, error) do
    Repo.update!(
      Ecto.Changeset.change(device, interval: interval, poll_after: DateTime.add(now, interval))
    )

    {:error, error}
  end

  defp exchange(device) do
    grant = Store.locked(from g in Grant, where: g.id == ^device.grant_id)

    case OAuth.authorize_grant(grant.id) do
      {:ok, _} ->
        Repo.update!(Ecto.Changeset.change(device, state: "spent"))
        {:ok, OAuth.issue(grant, grant.scopes, :user)}

      :error ->
        {:error, :invalid_grant}
    end
  end
end
