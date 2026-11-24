defmodule ForemanAgent.Runner.Collector do
  @moduledoc false
  # A Collectable that streams each chunk to a callback and keeps the
  # last `keep` bytes.
  #
  # Chunks come straight from a pipe, so one can end in the middle of a
  # character. Those bytes wait for the next chunk, and anything still
  # invalid is replaced, so the callback and the kept output only ever see
  # valid UTF-8 (events to the control plane are JSON).
  #
  # With `raw`, the kept output is the bytes as they came, for a caller
  # that parses them itself: a NUL-separated list can't survive being
  # made text. The callback still gets text.

  alias ForemanAgent.Text

  defstruct keep: 65_536, on_output: nil, raw: false, chunks: [], size: 0, carry: <<>>

  def output(%__MODULE__{chunks: chunks, keep: keep, raw: raw}) do
    binary = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      byte_size(binary) <= keep -> binary
      raw -> binary_part(binary, byte_size(binary) - keep, keep)
      true -> binary |> binary_part(byte_size(binary) - keep, keep) |> Text.trim_leading_partial()
    end
  end

  defimpl Collectable do
    alias ForemanAgent.Text

    def into(collector) do
      fun = fn
        acc, {:cont, chunk} ->
          {complete, carry} = Text.split_incomplete(acc.carry <> chunk)
          emit(%{acc | carry: carry}, complete)

        acc, :done ->
          %{emit(acc, acc.carry) | carry: <<>>}

        _acc, :halt ->
          :ok
      end

      {collector, fun}
    end

    defp emit(acc, <<>>), do: acc

    defp emit(acc, data) do
      shown = Text.scrub(data)
      acc.on_output.(shown)
      kept = if acc.raw, do: data, else: shown
      trim(%{acc | chunks: [kept | acc.chunks], size: acc.size + byte_size(kept)})
    end

    # Trims lazily, once twice the limit has built up.
    defp trim(%{size: size, keep: keep} = acc) when size <= keep * 2, do: acc

    defp trim(acc) do
      binary = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      kept = binary_part(binary, byte_size(binary) - acc.keep, acc.keep)
      kept = if acc.raw, do: kept, else: Text.trim_leading_partial(kept)

      %{acc | chunks: [kept], size: byte_size(kept)}
    end
  end
end
