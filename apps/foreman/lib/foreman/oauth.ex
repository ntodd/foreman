defmodule Foreman.OAuth do
  @moduledoc "Foreman bearer credentials and durable authorization for queued work."
  import Ecto.Query

  alias Foreman.{Accounts, Audit, Repo}
  alias Foreman.OAuth.{Client, Device, Grant, Principal, Store, Token}

  @access_seconds 900
  @refresh_days 90

  def authorize_grant(grant_id) do
    with {:ok, id} <- Ecto.UUID.cast(grant_id),
         %Grant{} = grant <- Repo.one(from g in live_grants(), where: g.id == ^id) do
      principal(grant)
    else
      _ -> :error
    end
  end

  def live_grants do
    # The issuer uses the application clock for token deadlines. A retained
    # query must also expire on the database clock when the statement runs.
    from g in Grant,
      join: c in assoc(g, :client),
      join: u in assoc(g, :user),
      where: is_nil(g.revoked_at) and is_nil(c.disabled_at) and is_nil(u.disabled_at),
      where: ^unexpired_grant(DateTime.utc_now())
  end

  defp unexpired_grant(issuer_now) do
    if Repo.sqlite?() do
      # Both Ecto ISO timestamps and space-separated SQLite timestamps are UTC.
      # SQLite resolves milliseconds; expire ambiguous submillisecond ties.
      issuer_utc = issuer_now |> DateTime.to_naive() |> NaiveDateTime.to_string()

      dynamic(
        [g],
        is_nil(g.expires_at) or
          fragment(
            "replace(rtrim(?, 'Z'), 'T', ' ') > max(?, strftime('%Y-%m-%d %H:%M:%f', 'now') || '999')",
            g.expires_at,
            ^issuer_utc
          )
      )
    else
      dynamic(
        [g],
        is_nil(g.expires_at) or
          (g.expires_at > ^issuer_now and
             g.expires_at > fragment("statement_timestamp() AT TIME ZONE 'UTC'"))
      )
    end
  end

  defp principal(grant) do
    user = Accounts.get_user(grant.user_id)

    cond do
      is_nil(user) or not is_nil(user.disabled_at) ->
        :error

      not user.service_account and Accounts.access(user) == :denied ->
        Accounts.revoke_access(user, "no longer allowed to use the API")
        :error

      true ->
        {:ok,
         %Principal{
           user: user,
           kind: if(user.service_account, do: :service_account, else: :user),
           grant_id: grant.id,
           client_id: grant.client_id,
           scopes: grant.scopes
         }}
    end
  end

  # Take the same lock order as user offboarding before issuing or rotating personal credentials.
  def lock_personal_grant(id, client_id) do
    grant = from g in Grant, where: g.id == ^id and g.client_id == ^client_id
    owner = from g in grant, select: g.user_id
    Repo.one_for_update(from u in Accounts.User, where: u.id in subquery(owner))
    Repo.one_for_update(grant)
  end

  def authenticate(raw) when is_binary(raw) and byte_size(raw) <= 128 do
    with %Token{} = token <- Repo.get_by(Token, digest: Store.digest(raw), kind: "access"),
         true <- DateTime.after?(token.expires_at, DateTime.utc_now()),
         {:ok, principal} <- authorize_grant(token.grant_id) do
      {:ok, %{principal | scopes: Enum.filter(token.scopes, &(&1 in principal.scopes))}}
    else
      _ -> :error
    end
  end

  def authenticate(_), do: :error

  # Call inside the grant's transaction so the rotation and both new credentials commit together.
  def issue(grant, scopes, kind) do
    now = DateTime.utc_now()

    result = %{
      access_token: insert_token(grant, "access", scopes, DateTime.add(now, @access_seconds)),
      token_type: "Bearer",
      expires_in: @access_seconds,
      scope: Enum.join(scopes, " ")
    }

    if kind == :user do
      expires = DateTime.add(now, @refresh_days, :day)
      Repo.update!(Ecto.Changeset.change(grant, expires_at: expires))
      Map.put(result, :refresh_token, insert_token(grant, "refresh", grant.scopes, expires))
    else
      result
    end
  end

  defp insert_token(grant, kind, scopes, expires) do
    raw = Store.random_secret()

    Repo.insert!(%Token{
      digest: Store.digest(raw),
      kind: kind,
      grant_id: grant.id,
      scopes: scopes,
      expires_at: expires
    })

    raw
  end

  def refresh(%Client{kind: "public", id: client_id}, raw, requested) when is_binary(raw) do
    # A reused refresh token revokes its family. Commit this outcome even though the wire response is an error.
    {:ok, result} =
      Repo.transact(fn ->
        {:ok,
         rotate(
           Repo.get_by(Token, digest: Store.digest(raw), kind: "refresh"),
           client_id,
           requested
         )}
      end)

    result
  end

  def refresh(_, _, _), do: {:error, :invalid_grant}

  defp rotate(%Token{} = token, client_id, requested) do
    grant = lock_personal_grant(token.grant_id, client_id)

    with %Grant{} <- grant,
         {:ok, _} <- authorize_grant(grant.id),
         true <- DateTime.after?(token.expires_at, DateTime.utc_now()),
         {:ok, scopes} <- optional_scopes(requested, grant.scopes) do
      if Repo.reload!(token).used_at do
        revoke_grant(grant.id)
        {:error, :invalid_grant}
      else
        Repo.update!(Ecto.Changeset.change(token, used_at: DateTime.utc_now()))
        {:ok, issue(grant, scopes, :user)}
      end
    else
      {:error, :invalid_scope} = error -> error
      _ -> {:error, :invalid_grant}
    end
  end

  defp rotate(_, _, _), do: {:error, :invalid_grant}

  def optional_scopes(nil, allowed), do: {:ok, allowed}
  def optional_scopes(requested, allowed), do: Store.requested_scopes(requested, allowed)

  def revoke(%Client{} = client, raw) when is_binary(raw) and raw != "" do
    Repo.transact(fn ->
      with %Token{} = token <- Repo.get_by(Token, digest: Store.digest(raw)),
           %Grant{} = grant <-
             Repo.one_for_update(
               from g in Grant, where: g.id == ^token.grant_id and g.client_id == ^client.id
             ) do
        if client.kind == "public",
          do: revoke_grant(grant.id),
          else: Repo.delete_all(from t in Token, where: t.id == ^token.id)
      end

      {:ok, :revoked}
    end)
  end

  def revoke(_, _), do: {:error, :invalid_request}

  def revoke_grant(id),
    do:
      Repo.update_all(from(g in Grant, where: g.id == ^id and is_nil(g.revoked_at)),
        set: [revoked_at: DateTime.utc_now()]
      )

  def revoke_user(id),
    do:
      Repo.update_all(from(g in Grant, where: g.user_id == ^id and is_nil(g.revoked_at)),
        set: [revoked_at: DateTime.utc_now()]
      )

  def connections(user_id) do
    Repo.all(
      from g in live_grants(),
        where: g.user_id == ^user_id,
        preload: [:client],
        order_by: [desc: g.inserted_at]
    )
  end

  def disconnect(user, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Grant{} <- Repo.get_by(Grant, id: id, user_id: user.id) do
      revoke_grant(id)
      Audit.log(user, "oauth.disconnected", {"Grant", id})
      :ok
    else
      _ -> :error
    end
  end

  def prune do
    now = DateTime.utc_now()
    # Keep recently expired codes long enough to give a delayed poll the specific expiry response.
    Repo.delete_all(from d in Device, where: d.expires_at < ^DateTime.add(now, -1, :day))
    Repo.delete_all(from t in Token, where: t.expires_at <= ^now)
  end
end
