defmodule Foreman.Operations.Redactions do
  @moduledoc """
  The secret values to scrub from each in-flight operation's logs and
  errors (see `ForemanProtocol.Redaction`). Filled when an operation is
  sent; rebuilt from the environment's secrets if the control plane
  restarted in between.
  """
  use GenServer

  alias Foreman.Environments.Environment
  alias Foreman.Operations.Operation
  alias Foreman.{Repo, Secrets}
  alias ForemanProtocol.{Command, Redaction}

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records what to redact for an operation, from its command and its environment's secrets."
  def put(op_id, %Command{payload: payload}, %Environment{} = env) do
    files =
      payload
      |> Map.get(:files, %{})
      |> Map.drop(["secrets.env", "gitconfig", "notices"])
      |> Map.values()

    compose = payload |> Map.get(:compose_env, %{}) |> Map.values()
    registry = (payload[:registry_auth] || []) |> Enum.map(& &1.token)
    resolved = env |> Secrets.resolve() |> Map.values()

    :ets.insert(@table, {op_id, Redaction.prepare(files ++ compose ++ registry ++ resolved)})
    :ok
  end

  def redact(op_id, text) do
    Redaction.redact(values(op_id), text)
  end

  def delete(op_id), do: :ets.delete(@table, op_id)

  defp values(op_id) do
    case :ets.lookup(@table, op_id) do
      [{_, values}] ->
        values

      [] ->
        values =
          case Repo.get(Operation, op_id) do
            %Operation{environment_id: env_id} when is_binary(env_id) ->
              case Repo.get(Environment, env_id) do
                nil -> []
                env -> env |> Secrets.resolve() |> Map.values() |> Redaction.prepare()
              end

            _ ->
              []
          end

        :ets.insert(@table, {op_id, values})
        values
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
