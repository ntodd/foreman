defmodule Foreman.OAuth.EnvironmentConnection do
  @moduledoc """
  The connection an environment has to the public API from inside itself.

  A box relays the request and says which of its environments sent it.
  The request then acts as that environment's owner, on a grant that
  reaches that one environment: its state, operations, logs and secrets,
  and stopping and starting it (`Foreman.OAuth.Scopes.environment/0`).
  No token is ever issued for the grant, so there is nothing in the
  environment to copy out.

  The grant is an ordinary one otherwise. Work it queues is authorized
  again by its id, like any connection's, and it ends when the owner is
  disabled or the environment is destroyed.

  It gives the environment no credentials and changes none. A restart it
  asks for runs on the authority the environment already runs on, with
  the credentials that authority gives it, and is refused when that
  authority is gone (`grant?/1`).
  """
  import Ecto.Query

  alias Foreman.Accounts.User
  alias Foreman.Boxes.Box
  alias Foreman.Environments.Environment
  alias Foreman.OAuth
  alias Foreman.OAuth.{Grant, Scopes}
  alias Foreman.Repo

  @client "foreman-environment"

  def client_id, do: @client

  @doc """
  The principal for a request `box_id` relayed for `env_id`. One answer
  for every refusal: a box learns nothing about an environment that isn't
  its own.
  """
  @spec principal(term(), term()) :: {:ok, OAuth.Principal.t()} | {:error, :not_found}
  def principal(box_id, env_id) do
    with {:ok, box_id} <- uuid(box_id),
         {:ok, env_id} <- uuid(env_id),
         %{user_id: user_id} <- Repo.one(hosted(box_id, env_id)),
         %Grant{} = grant <- grant(env_id, user_id),
         {:ok, principal} <- OAuth.authorize_grant(grant.id) do
      {:ok, principal}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Whether `grant_id` is an environment's own grant, live or not.

  Who asked for a state and whose authority supplies an environment's
  credentials are two things. Such a grant can be the first: a stop or a
  start asked from inside is recorded as its request, and a repair of
  that state is authorized as it was. It is never the second: it isn't
  recorded as the grant an environment runs on, doesn't take a workspace
  over from the connection that launched it, and isn't what credentials
  are made from. Otherwise an environment could renew its own
  credentials after the connection that launched it was revoked.
  """
  def grant?(nil), do: false

  def grant?(grant_id) do
    Repo.exists?(from g in Grant, where: g.id == ^grant_id and not is_nil(g.environment_id))
  end

  @doc "Whether the environment a grant was made for is still its owner's and not destroyed."
  def live?(%Grant{environment_id: id, user_id: user_id}) when is_binary(id) do
    Repo.exists?(
      from e in Environment,
        join: u in User,
        on: u.id == e.user_id and is_nil(u.workload_access_revoked_at),
        where: e.id == ^id and e.user_id == ^user_id and is_nil(e.destroyed_at)
    )
  end

  def live?(_grant), do: false

  # A live environment on a box that is still enrolled, owned by a person
  # who can still sign in. One whose access was taken away has their
  # grants revoked with it, and gets no new one here until they've signed
  # in again. A service account manages no secrets, so its environments
  # get no connection.
  defp hosted(box_id, env_id) do
    from e in Environment,
      join: b in Box,
      on: b.id == e.box_id and is_nil(b.revoked_at),
      join: u in User,
      on:
        u.id == e.user_id and is_nil(u.disabled_at) and not u.service_account and
          is_nil(u.workload_access_revoked_at),
      where: e.id == ^env_id and e.box_id == ^box_id and is_nil(e.destroyed_at),
      select: %{user_id: e.user_id}
  end

  defp grant(env_id, user_id) do
    scopes = Scopes.environment()
    now = DateTime.utc_now()

    # Nothing is inserted when the environment already has a live grant
    # (the partial unique index), including one a concurrent request is
    # committing.
    Repo.insert_all(
      Grant,
      [
        %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          client_id: @client,
          scopes: scopes,
          environment_id: env_id,
          repo_ids: [],
          box_ids: [],
          secret_ids: [],
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    live =
      from g in Grant,
        where: g.environment_id == ^env_id and g.user_id == ^user_id and is_nil(g.revoked_at)

    case Repo.one(live) do
      %Grant{scopes: ^scopes} = grant ->
        grant

      # Made by a release with a different list of actions.
      %Grant{} = grant ->
        grant |> Ecto.Changeset.change(scopes: scopes) |> Repo.update!()

      nil ->
        nil
    end
  end

  defp uuid(value) when is_binary(value) and byte_size(value) == 36, do: Ecto.UUID.cast(value)
  defp uuid(_), do: :error
end
