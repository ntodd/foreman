defmodule Foreman.DatabaseText do
  @moduledoc "Checks decoded JSON for text PostgreSQL cannot store."

  def contains_nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  def contains_nul?(value) when is_list(value), do: Enum.any?(value, &contains_nul?/1)

  def contains_nul?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} -> contains_nul?(key) or contains_nul?(item) end)
  end

  def contains_nul?(_value), do: false
end
