defmodule Foreman.Agents.RelayNonce do
  @moduledoc """
  The nonces of relayed requests the control plane has accepted
  (`ForemanWeb.Plugs.RelayAuth`), so none is accepted twice.

  A relayed request can change something each time it is accepted (a
  secret has no idempotency key), so unlike an agent connect's nonce
  these outlive the process: they are claimed in the database, where a
  control plane that restarted, or a second one, sees them too. Each is
  kept for three times the allowed clock skew from its request's own
  timestamp, well past when that timestamp could still pass anywhere.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Foreman.Repo

  @primary_key {:nonce, :string, autogenerate: false}
  schema "relay_nonces" do
    field :expires_at, :utc_datetime_usec
  end

  @doc """
  :ok the first time a nonce is claimed, on any node; :replay after that.

  `signed_at` is the request's own timestamp, in Unix seconds. The row is
  kept by that and not by this node's clock: a request is acceptable
  until its timestamp is the allowed skew in the past, on whichever node
  checks it, so the nonce stays well past that second.
  """
  @spec claim(String.t(), integer()) :: :ok | :replay
  def claim(nonce, signed_at) when is_binary(nonce) and is_integer(signed_at) do
    expires =
      DateTime.from_unix!(
        (signed_at + 3 * ForemanProtocol.Auth.max_skew()) * 1_000_000,
        :microsecond
      )

    case Repo.insert_all(__MODULE__, [%{nonce: nonce, expires_at: expires}],
           on_conflict: :nothing
         ) do
      {1, _} -> :ok
      _ -> :replay
    end
  end

  @doc "Removes the nonces of requests too old to be accepted again."
  def prune(now \\ DateTime.utc_now()),
    do: Repo.delete_all(from n in __MODULE__, where: n.expires_at < ^now)
end
