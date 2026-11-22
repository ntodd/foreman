defmodule ForemanProtocol.Jsonc do
  @moduledoc """
  Parses JSON with comments and trailing commas, the dialect
  devcontainer.json is written in.

  Comments are blanked out and trailing commas dropped, both only outside
  strings, and the result goes to the standard JSON decoder. Errors never
  include the input: devcontainer.json lives in a repo the agent doesn't
  trust, and a parse error shouldn't become a way to read a file back.
  """

  @spec decode(binary()) :: {:ok, map()} | {:error, String.t()}
  def decode(input) when is_binary(input) do
    cleaned = clean(input)

    case JSON.decode(cleaned) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, "devcontainer.json must contain an object"}

      {:error, {:unexpected_end, _}} ->
        {:error, "invalid JSON: unexpected end of input"}

      {:error, {_reason, position, _detail}} when is_integer(position) ->
        {:error, "invalid JSON at byte #{position}"}

      {:error, _} ->
        {:error, "invalid JSON"}
    end
  end

  @doc """
  The keys of the object at `path` (a list of keys from the top), in the
  order they're written. A decoded map doesn't keep that order, and for
  some objects it matters: environment variables that build on each other.
  Empty when there's no object there.
  """
  @spec key_order(binary(), [String.t()]) :: [String.t()]
  def key_order(input, path) when is_binary(input) and is_list(path) do
    cleaned = clean(input)

    decoders = %{
      object_push: fn key, value, acc -> [{key, value} | acc] end,
      object_finish: fn acc, old_acc -> {{:object, Enum.reverse(acc)}, old_acc} end
    }

    case :json.decode(cleaned, :ok, decoders) do
      {value, :ok, rest} -> if String.trim(rest) == "", do: keys_at(value, path), else: []
    end
  rescue
    ErlangError -> []
  end

  defp clean(input), do: input |> strip_comments() |> strip_trailing_commas()

  defp keys_at({:object, pairs}, []), do: Enum.map(pairs, &elem(&1, 0))

  defp keys_at({:object, pairs}, [key | rest]) do
    case List.keyfind(pairs, key, 0) do
      {_, value} -> keys_at(value, rest)
      nil -> []
    end
  end

  defp keys_at(_value, _path), do: []

  # Replace comments and a leading UTF-8 BOM with spaces to keep byte offsets.
  defp strip_comments(<<0xEF, 0xBB, 0xBF, rest::binary>>),
    do: strip_comments(rest, :code, ["   "])

  defp strip_comments(input), do: strip_comments(input, :code, [])

  defp strip_comments(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_comments(<<"\"", rest::binary>>, :code, acc),
    do: strip_comments(rest, :string, ["\"" | acc])

  defp strip_comments(<<"//", rest::binary>>, :code, acc),
    do: strip_comments(rest, :line, ["  " | acc])

  defp strip_comments(<<"/*", rest::binary>>, :code, acc),
    do: strip_comments(rest, :block, ["  " | acc])

  defp strip_comments(<<"\\", c, rest::binary>>, :string, acc),
    do: strip_comments(rest, :string, [<<"\\", c>> | acc])

  defp strip_comments(<<"\"", rest::binary>>, :string, acc),
    do: strip_comments(rest, :code, ["\"" | acc])

  defp strip_comments(<<"\n", rest::binary>>, :line, acc),
    do: strip_comments(rest, :code, ["\n" | acc])

  defp strip_comments(<<_, rest::binary>>, :line, acc),
    do: strip_comments(rest, :line, [" " | acc])

  defp strip_comments(<<"*/", rest::binary>>, :block, acc),
    do: strip_comments(rest, :code, ["  " | acc])

  defp strip_comments(<<"\n", rest::binary>>, :block, acc),
    do: strip_comments(rest, :block, ["\n" | acc])

  defp strip_comments(<<_, rest::binary>>, :block, acc),
    do: strip_comments(rest, :block, [" " | acc])

  defp strip_comments(<<c, rest::binary>>, state, acc),
    do: strip_comments(rest, state, [<<c>> | acc])

  defp strip_trailing_commas(input), do: strip_commas(input, :code, [])

  defp strip_commas(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_commas(<<"\"", rest::binary>>, :code, acc),
    do: strip_commas(rest, :string, ["\"" | acc])

  defp strip_commas(<<"\\", c, rest::binary>>, :string, acc),
    do: strip_commas(rest, :string, [<<"\\", c>> | acc])

  defp strip_commas(<<"\"", rest::binary>>, :string, acc),
    do: strip_commas(rest, :code, ["\"" | acc])

  defp strip_commas(<<",", rest::binary>>, :code, acc) do
    if closes_next?(rest),
      do: strip_commas(rest, :code, [" " | acc]),
      else: strip_commas(rest, :code, ["," | acc])
  end

  defp strip_commas(<<c, rest::binary>>, state, acc), do: strip_commas(rest, state, [<<c>> | acc])

  defp closes_next?(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: closes_next?(rest)
  defp closes_next?(<<c, _::binary>>) when c in [?}, ?]], do: true
  defp closes_next?(_), do: false
end
