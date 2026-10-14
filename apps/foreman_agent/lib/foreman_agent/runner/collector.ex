defmodule ForemanAgent.Runner.Collector do
  @moduledoc false
  # A Collectable that streams each chunk to a callback and keeps the
  # last `keep` bytes.
  defstruct keep: 65_536, on_output: nil, chunks: [], size: 0

  def output(%__MODULE__{chunks: chunks, keep: keep}) do
    binary = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    if byte_size(binary) > keep,
      do: binary_part(binary, byte_size(binary) - keep, keep),
      else: binary
  end

  defimpl Collectable do
    def into(collector) do
      fun = fn
        acc, {:cont, chunk} ->
          acc.on_output.(chunk)
          trim(%{acc | chunks: [chunk | acc.chunks], size: acc.size + byte_size(chunk)})

        acc, :done ->
          acc

        _acc, :halt ->
          :ok
      end

      {collector, fun}
    end

    # Trims lazily, once twice the limit has built up.
    defp trim(%{size: size, keep: keep} = acc) when size <= keep * 2, do: acc

    defp trim(acc) do
      binary = acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
      kept = binary_part(binary, byte_size(binary) - acc.keep, acc.keep)
      %{acc | chunks: [kept], size: byte_size(kept)}
    end
  end
end
