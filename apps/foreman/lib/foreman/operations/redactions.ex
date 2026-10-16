defmodule Foreman.Operations.Redactions do
  @moduledoc """
  The secret values to scrub from each in-flight operation's logs and
  errors (see `ForemanProtocol.Redaction`). Filled when an operation is
  sent; rebuilt from the environment's secrets if the control plane
  restarted in between.
  """
  use GenServer

  import Ecto.Query

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

  @doc """
  Splits `text` into what can be shown now and its longest tail that is
  the start of one of the operation's secrets (the rest may be in the next
  read), which has to wait.
  """
  @spec hold_back(String.t(), binary()) :: {binary(), binary()}
  def hold_back(op_id, text) do
    size = byte_size(text)

    keep =
      op_id
      |> values()
      |> secret_values()
      |> Enum.map(fn value -> longest_start(value, text, min(byte_size(value) - 1, size)) end)
      |> Enum.max(fn -> 0 end)

    {binary_part(text, 0, size - keep), binary_part(text, size - keep, keep)}
  end

  defp secret_values(%Redaction{values: values}), do: values
  defp secret_values(values) when is_list(values), do: values

  # The length of the longest tail of `text` that `value` starts with.
  defp longest_start(_value, _text, 0), do: 0

  defp longest_start(value, text, k) do
    if binary_part(text, byte_size(text) - k, k) == binary_part(value, 0, k),
      do: k,
      else: longest_start(value, text, k - 1)
  end

  def delete(op_id), do: :ets.delete(@table, op_id)

  @doc """
  Drops entries for operations that are over (a log chunk arriving after
  the result rebuilds one) or gone. Returns how many were dropped.
  """
  def prune do
    ids = :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])

    active =
      Repo.all(
        from o in Operation,
          where: o.id in ^ids and o.status in ["queued", "dispatched", "running"],
          select: o.id
      )
      |> MapSet.new()

    stale = Enum.reject(ids, &MapSet.member?(active, &1))
    Enum.each(stale, &delete/1)
    length(stale)
  end

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
