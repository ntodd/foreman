defmodule ForemanAgent.Runner.Collector do
  @moduledoc false
  # A Collectable that streams each chunk to a callback and keeps the
  # last `keep` bytes.
  #
  # Chunks come straight from a pipe, so one can end in the middle of a
  # character. Those bytes wait for the next chunk, and anything still
  # invalid is replaced, so the callback and the kept output only ever see
  # valid UTF-8 (events to the control plane are JSON).

  alias ForemanAgent.Text

  defstruct keep: 65_536, on_output: nil, chunks: [], size: 0, carry: <<>>

  def output(%__MODULE__{chunks: chunks, keep: keep}) do
    binary = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    if byte_size(binary) > keep,
      do: binary |> binary_part(byte_size(binary) - keep, keep) |> Text.trim_leading_partial(),
      else: binary
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
      data = Text.scrub(data)
      acc.on_output.(data)
      trim(%{acc | chunks: [data | acc.chunks], size: acc.size + byte_size(data)})
    end

    # Trims lazily, once twice the limit has built up.
    defp trim(%{size: size, keep: keep} = acc) when size <= keep * 2, do: acc

    defp trim(acc) do
      binary = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      kept =
        binary
        |> binary_part(byte_size(binary) - acc.keep, acc.keep)
        |> Text.trim_leading_partial()

      %{acc | chunks: [kept], size: byte_size(kept)}
    end
  end
end
