defmodule Foreman.OAuth.Store do
  @moduledoc false

  def random_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  def digest(value), do: :crypto.hash(:sha256, value)

  def validate_scopes(scopes, allowed) when is_list(scopes) do
    if scopes != [] and Enum.all?(scopes, &(&1 in allowed)),
      do: {:ok, Enum.uniq(scopes)},
      else: {:error, :invalid_scope}
  end

  def validate_scopes(_, _), do: {:error, :invalid_scope}

  def requested_scopes(scope, allowed) when is_binary(scope),
    do: validate_scopes(String.split(scope, " ", trim: true), allowed)

  def requested_scopes(_, _), do: {:error, :invalid_scope}
end
