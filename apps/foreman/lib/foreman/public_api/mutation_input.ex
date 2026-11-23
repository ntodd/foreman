defmodule Foreman.PublicAPI.MutationInput do
  @moduledoc false

  def key(key) when is_binary(key) do
    if String.trim(key) == "", do: invalid("Supply an Idempotency-Key header."), else: :ok
  end

  def key(_), do: invalid("Supply one Idempotency-Key header.")

  def create(input) when is_map(input) do
    with :ok <- only(input, ~w(repo_id box_id branch expiry confirm_capacity_warning)),
         {:ok, id} <- uuid(input["repo_id"]),
         {:ok, input} <- optional(input, "box_id", &uuid/1),
         {:ok, input} <- optional(input, "branch", &branch/1),
         {:ok, input} <- optional(input, "expiry", &expiry/1),
         {:ok, input} <- confirmation(input) do
      {:ok, Map.put(input, "repo_id", id)}
    end
  end

  def create(_), do: invalid("The create body must be an object.")

  def action(%{"action" => action} = input)
      when action in ~w(start stop destroy restart_affected restart_all) do
    with :ok <- only(input, ~w(action confirm_capacity_warning)), do: confirmation(input)
  end

  def action(_), do: invalid("Choose start, stop, destroy, restart_affected or restart_all.")

  def uuid(value) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid("Supply a valid UUID.")
    end
  end

  def uuid(_), do: invalid("Supply a valid UUID.")

  defp optional(input, key, cast) do
    if Map.has_key?(input, key) do
      with {:ok, value} <- cast.(input[key]), do: {:ok, Map.put(input, key, value)}
    else
      {:ok, input}
    end
  end

  defp confirmation(input) do
    case Map.get(input, "confirm_capacity_warning", false) do
      confirmed when is_boolean(confirmed) ->
        {:ok, Map.put(input, "confirm_capacity_warning", confirmed)}

      _ ->
        invalid("confirm_capacity_warning must be a boolean.")
    end
  end

  defp only(input, keys) do
    if Map.keys(input) -- keys == [],
      do: :ok,
      else: invalid("The request contains an unknown field.")
  end

  defp branch(value) do
    case ForemanProtocol.Schema.cast(%{"branch" => value}, branch: {:git_ref, required: true}) do
      {:ok, _} -> {:ok, value}
      _ -> invalid("Supply a valid git branch name.")
    end
  end

  defp expiry(%{"at" => at, "action" => action} = policy)
       when is_binary(at) and action in ~w(stop destroy) and map_size(policy) == 2 do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} ->
        # Compare instants, including equivalent offsets and fractional precision.
        canonical = dt |> DateTime.to_unix(:microsecond) |> DateTime.from_unix!(:microsecond)
        {:ok, %{"at" => DateTime.to_iso8601(canonical), "action" => action}}

      _ ->
        invalid("expiry.at must be an absolute ISO 8601 date-time.")
    end
  end

  defp expiry(_), do: invalid("Expiry requires a deadline and a stop or destroy action.")
  defp invalid(message), do: {:error, :invalid_request, message}
end
