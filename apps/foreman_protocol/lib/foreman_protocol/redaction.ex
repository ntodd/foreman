defmodule ForemanProtocol.Redaction do
  @moduledoc """
  Replaces known secret values in text. Shared by the agent (which
  redacts what a command carried before output leaves the box) and the
  control plane (which redacts an environment's secrets from everything
  it stores or shows, including container logs the agent can't know to
  scrub).

  Values shorter than #{6} characters are left alone; redacting "on" or
  "4000" would mangle ordinary output. Multi-line values are matched
  line by line as well as whole.

  `prepare/1` compiles the values into one search pattern, so redacting
  a line costs a single scan however many values there are. Matches that
  overlap (one value's tail is another's head) are merged and masked
  together, so no part of either is left behind.
  """

  @min_length 6
  @mask "[redacted]"

  defstruct values: [], pattern: nil, max_length: 0, single_line?: true

  @type t :: %__MODULE__{
          values: [String.t()],
          pattern: :binary.cp() | nil,
          max_length: non_neg_integer(),
          single_line?: boolean()
        }

  @doc """
  The values to redact for an environment's variables: each value, and
  each credential inside `DEVCONTAINERS_OCI_AUTH`
  (`registry|user|token`, comma-separated), which is used a token at a
  time.
  """
  @spec env_values(%{optional(String.t()) => String.t()}) :: [String.t()]
  def env_values(env) do
    tokens =
      for entry <- String.split(env["DEVCONTAINERS_OCI_AUTH"] || "", ","),
          [_registry, _user, token] <- [String.split(entry, "|")],
          do: token

    Map.values(env) ++ tokens
  end

  @doc "Prepares a list of values for `redact/2`."
  @spec prepare([String.t()]) :: t()
  def prepare(values) do
    values =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&[&1 | String.split(&1, "\n")])
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) >= @min_length))
      |> Enum.uniq()
      # Longest first, so a value containing another is replaced whole.
      |> Enum.sort_by(&(-byte_size(&1)))

    %__MODULE__{
      values: values,
      single_line?: single_line?(values),
      pattern: if(values != [], do: :binary.compile_pattern(values)),
      max_length: values |> Enum.map(&byte_size/1) |> Enum.max(fn -> 0 end)
    }
  end

  @doc "The byte size of the longest value, so callers can carry that much between chunks."
  @spec max_length(t()) :: non_neg_integer()
  def max_length(%__MODULE__{max_length: max}), do: max

  @doc """
  Masks every value in `text`. Accepts a prepared set, or a plain list of
  already-prepared values (compiled on each call).
  """
  @spec redact(t() | [String.t()], term()) :: term()
  def redact(prepared, text)
      when is_binary(text) and (is_struct(prepared, __MODULE__) or is_list(prepared)) do
    case match_ranges(prepared, text) do
      [] -> text
      ranges -> splice(ranges, text)
    end
  end

  def redact(_prepared, other), do: other

  @doc """
  Redacts the first `cut` bytes using matches in the whole text. The
  returned count is the number of retained bytes covered by a mask already
  emitted. Pass that count with the raw tail on the next read so overlapping
  values are still recognized and their shared bytes are shown only once.
  """
  def redact_prefix(prepared, text, cut, covered) do
    {parts, pos} =
      prepared
      |> match_ranges(text)
      |> Enum.reduce_while({[], covered}, fn
        {start, _stop}, acc when start >= cut ->
          {:halt, acc}

        {start, stop}, {parts, pos} when pos > 0 and start <= pos ->
          {:cont, {parts, max(pos, stop)}}

        {start, stop}, {parts, pos} ->
          {:cont, {[@mask, binary_part(text, pos, start - pos) | parts], stop}}
      end)

    last = min(pos, cut)
    shown = Enum.reverse([binary_part(text, last, cut - last) | parts])
    {IO.iodata_to_binary(shown), max(0, pos - cut)}
  end

  defp match_ranges(%__MODULE__{pattern: nil}, _text), do: []
  defp match_ranges([], _text), do: []

  defp match_ranges(%__MODULE__{pattern: pattern} = prepared, text),
    do: match_ranges(text, pattern, Map.get(prepared, :single_line?, false))

  defp match_ranges(values, text) when is_list(values),
    do: match_ranges(text, :binary.compile_pattern(values), single_line?(values))

  defp single_line?(values), do: Enum.all?(values, &(:binary.match(&1, "\n") == :nomatch))

  defp match_ranges(text, pattern, single_line?) do
    case :binary.match(text, pattern) do
      :nomatch -> []
      first -> ranges(text, pattern, first, [], 0, single_line?)
    end
  end

  # Every match, including ones that start inside an earlier match, merged
  # into non-overlapping {start, stop} ranges in order. :binary.match finds
  # the leftmost match (the longest at that position), so searching again
  # from one byte past its start finds anything overlapping it.
  defp ranges(text, pattern, {start, len}, acc, credit, single_line?) do
    stop = start + len

    # An overlapping search pays for bytes it revisits. New coverage buys
    # constant work per byte. Once spent, cover the remainder conservatively.
    credit =
      case acc do
        [{_, last} | _] when start < last -> credit + 4 * max(stop - last, 0) - len
        _ -> max(256, 4 * len)
      end

    {acc, from} =
      if credit < 0 do
        [{_, last} | _] = acc
        boundary = mask_until(text, max(last, stop), single_line?)
        {merge(acc, start, boundary), boundary}
      else
        {merge(acc, start, stop), start + 1}
      end

    case :binary.match(text, pattern, scope: {from, byte_size(text) - from}) do
      :nomatch -> Enum.reverse(acc)
      next -> ranges(text, pattern, next, acc, credit, single_line?)
    end
  end

  defp mask_until(text, _from, false), do: byte_size(text)

  defp mask_until(text, from, true) do
    case :binary.match(text, "\n", scope: {from, byte_size(text) - from}) do
      {newline, 1} -> newline
      :nomatch -> byte_size(text)
    end
  end

  defp merge([{s, e} | rest], start, stop) when start <= e, do: [{s, max(e, stop)} | rest]
  defp merge(acc, start, stop), do: [{start, stop} | acc]

  defp splice(ranges, text) do
    {parts, last} =
      Enum.reduce(ranges, {[], 0}, fn {start, stop}, {parts, pos} ->
        {[@mask, binary_part(text, pos, start - pos) | parts], stop}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(text, last, byte_size(text) - last) | parts]))
  end
end
