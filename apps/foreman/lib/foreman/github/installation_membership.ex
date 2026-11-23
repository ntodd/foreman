defmodule Foreman.GitHub.InstallationMembership do
  @moduledoc "Scan a user's installation pages for requested GitHub ID and name pairs."

  def find(wanted, fetch) do
    if MapSet.size(wanted) == 0,
      do: {:ok, wanted},
      else: scan(1, %{wanted: wanted, found: MapSet.new(), pages: MapSet.new(), count: 0}, fetch)
  end

  defp scan(page, state, fetch) do
    with {:ok, response} <- fetch.(page) do
      case response.body do
        %{"repositories" => rows} when is_list(rows) ->
          collect(rows, response, page, state, fetch)

        _ ->
          {:error, :invalid_membership_page}
      end
    end
  end

  defp collect(rows, response, page, state, fetch) do
    identities =
      for %{"id" => id, "full_name" => name} <- rows,
          is_integer(id) and is_binary(name),
          into: MapSet.new(),
          do: {id, String.downcase(name)}

    found = MapSet.union(state.found, MapSet.intersection(identities, state.wanted))
    count = state.count + length(rows)
    # Keep a digest for each visited page, never the full installation.
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(identities)))

    cond do
      found == state.wanted ->
        {:ok, found}

      MapSet.member?(state.pages, fingerprint) ->
        {:error, :repeated_membership_page}

      more?(response, length(rows), count) ->
        scan(
          page + 1,
          %{state | found: found, count: count, pages: MapSet.put(state.pages, fingerprint)},
          fetch
        )

      true ->
        {:ok, found}
    end
  end

  # GitHub uses numbered pages on this endpoint. A next relation advances
  # that number on our original URL; no server-provided URL receives the token.
  defp more?(response, size, count) do
    links = Req.Response.get_header(response, "link")
    total = response.body["total_count"]

    cond do
      Enum.any?(links, &Regex.match?(~r/;\s*rel\s*=\s*(?:"next"|next)(?=[\s;,]|$)/i, &1)) -> true
      is_integer(total) -> size > 0 and count < total
      links == [] -> size == 100
      true -> false
    end
  end
end
