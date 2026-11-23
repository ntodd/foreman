defmodule Foreman.Jobs.EnvironmentExpiry do
  @moduledoc "Transfers an authorized expiry policy to the durable agent queue when it comes due."
  use Oban.Worker, queue: :default

  alias Foreman.{Environments, Repo, Scope}
  alias Foreman.Environments.{Environment, Server}

  def schedule!(%Environment{expiry_at: nil}), do: :ok

  def schedule!(%Environment{id: id, expiry_at: at}) do
    %{"environment_id" => id}
    |> new(scheduled_at: at)
    |> Oban.insert!()
  end

  @impl true
  def perform(%{args: %{"environment_id" => id}}) do
    {:ok, result} =
      Repo.transact(fn ->
        env = Environments.locked_environment(id)
        {:ok, consider(env)}
      end)

    case result do
      :queued ->
        unless Repo.in_transaction?(), do: Server.kick(id)
        :ok

      other ->
        other
    end
  end

  def due?(%{expiry_consumed_at: nil, expiry_at: %DateTime{} = at, destroyed_at: nil}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  def due?(_), do: false

  defp consider(nil), do: :ok
  defp consider(%{expiry_at: nil}), do: :ok
  defp consider(%{destroyed_at: at}) when not is_nil(at), do: :ok
  defp consider(%{expiry_consumed_at: at}) when not is_nil(at), do: :ok

  defp consider(env) do
    active = Repo.all(Environments.active_lifecycle(env.id))

    cond do
      not due?(env) ->
        {:snooze, max(1, DateTime.diff(env.expiry_at, DateTime.utc_now()))}

      Enum.any?(active, &(&1.trigger == "expiry")) ->
        :ok

      active != [] ->
        {:snooze, 5}

      true ->
        {:ok, _op} = queue(env)
        :queued
    end
  end

  @doc "Queues system work for a due policy, with the environment locked and its lifecycle queue idle."
  def queue(env) do
    Environments.queue_action(%Scope{}, env, String.to_existing_atom(env.expiry_action), %{},
      trigger: "expiry",
      audit: %{"trigger" => "expiry"}
    )
  end
end
