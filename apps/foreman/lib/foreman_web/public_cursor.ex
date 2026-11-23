defmodule ForemanWeb.PublicCursor do
  @moduledoc "Encrypted keyset positions bound to a grant and its resource collection."

  @salt "public read cursor v1"

  def context(principal, resource),
    do: {principal.kind, principal.user.id, principal.client_id, principal.grant_id, resource}

  def encode(context, position),
    do: Phoenix.Token.encrypt(ForemanWeb.Endpoint, @salt, {context, position})

  def decode(_context, nil), do: {:ok, nil}

  def decode(context, token) when is_binary(token) and byte_size(token) <= 4096 do
    case Phoenix.Token.decrypt(ForemanWeb.Endpoint, @salt, token, max_age: :infinity) do
      {:ok, {^context, position}} -> {:ok, position}
      _ -> {:error, :cursor}
    end
  end

  def decode(_context, _token), do: {:error, :cursor}
end
