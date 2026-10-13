defmodule ForemanAgent.Jsonc do
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
    cleaned = input |> strip_comments() |> strip_trailing_commas()

    case JSON.decode(cleaned) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _} ->
        {:error, "devcontainer.json must contain an object"}

      {:error, {:unexpected_end, _}} ->
        {:error, "invalid JSON: unexpected end of input"}

      {:error, {_reason, position}} when is_integer(position) ->
        {:error, "invalid JSON at byte #{position}"}

      {:error, _} ->
        {:error, "invalid JSON"}
    end
  end

  # Replaces comments with spaces so byte positions in errors still line up.
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
