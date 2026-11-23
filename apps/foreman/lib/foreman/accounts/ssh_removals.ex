defmodule Foreman.Accounts.SSHRemovals do
  @moduledoc """
  Durable tailnet administrator handoff. Foreman guests run tailscaled --ssh,
  whose policy revocation also terminates established sessions. The shipped
  Tailscale integration cannot selectively deny only future logins.
  """
  import Ecto.Query

  alias Foreman.{Accounts, Audit, Repo, Tailscale}
  alias Foreman.Accounts.User
  alias Foreman.Environments.Environment

  def record!(user) do
    if Tailscale.configured?() or
         Repo.exists?(
           from e in Environment,
             where: is_nil(e.destroyed_at) and not is_nil(e.tailscale_device_id)
         ) do
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [ssh_removal_id: Ecto.UUID.generate()]
      )
    end

    :ok
  end

  def outstanding do
    Repo.all(
      from u in User,
        where: not is_nil(u.ssh_removal_id),
        order_by: u.login,
        select: %{login: u.login, name: u.name, id: u.ssh_removal_id}
    )
  end

  def acknowledge(scope, removal_id) do
    case Ecto.UUID.cast(removal_id) do
      {:ok, id} ->
        Repo.transact(fn ->
          with {:ok, actor} <- Accounts.lock_admin(scope), do: clear(actor, id)
        end)

      :error ->
        {:error, :unauthorized}
    end
  end

  defp clear(actor, id) do
    case Repo.update_all(from(u in User, where: u.ssh_removal_id == ^id, select: u.id),
           set: [ssh_removal_id: nil]
         ) do
      {1, [user_id]} ->
        Audit.log(actor, "user.ssh_removal_acknowledged", {"User", user_id}, %{"removal_id" => id})

        {:ok, :acknowledged}

      _ ->
        {:error, :not_found}
    end
  end
end
