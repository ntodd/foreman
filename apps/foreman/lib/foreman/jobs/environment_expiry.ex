defmodule Foreman.Jobs.EnvironmentExpiry do
  @moduledoc "Transfers an authorized expiry policy to the durable agent queue when it comes due."
  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Foreman.{Environments, Repo, Scope}
  alias Foreman.Environments.{Environment, Server}

  def schedule!(%Environment{expiry_at: nil}), do: :ok

  def schedule!(%Environment{id: id, expiry_at: at}) do
    %{"environment_id" => id}
    |> new(scheduled_at: at)
    |> Oban.insert!()
  end

  def retry!(%Environment{id: id}) do
    %{"environment_id" => id}
    |> new(schedule_in: 60)
    |> Oban.insert!()
  end

  # A reconnect or the periodic dispatcher can beat the scheduled Oban
  # job. While due, send only system cleanup, preserving any in-flight work.
  # A failed attempt already scheduled a delayed retry in its result transaction.
  def next_due(id) do
    {:ok, op} =
      Repo.transact(fn ->
        env = Environments.locked_environment(id)

        if due?(env) do
          attempts =
            from o in Foreman.Operations.Operation,
              where: o.environment_id == ^id and o.trigger == "expiry"

          if Repo.exists?(attempts) do
            {:ok, Repo.one(from o in attempts, where: o.status == "queued", limit: 1)}
          else
            reserve(env)
          end
        else
          {:ok, nil}
        end
      end)

    op
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
    if due?(env) do
      {:ok, _op} = reserve(env)
      :queued
    else
      {:snooze, max(1, DateTime.diff(env.expiry_at, DateTime.utc_now()))}
    end
  end

  @doc "Reserve the system operation with the environment locked. The normal dispatcher serializes it behind in-flight work."
  def reserve(env) do
    queued =
      from o in Environments.active_lifecycle(env.id), where: o.trigger == "expiry", limit: 1

    case Repo.one(queued) do
      nil ->
        Environments.queue_action(%Scope{}, env, String.to_existing_atom(env.expiry_action), %{},
          dedupe: false,
          trigger: "expiry",
          audit: %{"trigger" => "expiry"}
        )

      op ->
        {:ok, op}
    end
  end
end
