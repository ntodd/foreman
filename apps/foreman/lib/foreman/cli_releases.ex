defmodule Foreman.CLIReleases do
  @moduledoc """
  Resolves the stable CLI tag for the shell bootstrap. The client downloads and
  verifies its archive directly from the official repository without a JSON tool.
  """

  @feed "https://api.github.com/repos/ntodd/foreman/releases"
  @targets ~w(linux-amd64 linux-arm64 darwin-amd64 darwin-arm64)

  # The public bootstrap shares GitHub's anonymous request budget with other
  # installations on this instance. Coalesce simultaneous discoveries.
  @cache {__MODULE__, :stable}

  def latest do
    :global.trans(
      {@cache, self()},
      fn ->
        now = System.monotonic_time(:second)

        case :persistent_term.get(@cache, nil) do
          {deadline, result} when deadline > now ->
            result

          _ ->
            result = discover()
            ttl = if result == :error, do: 10, else: 120
            :persistent_term.put(@cache, {now + ttl, result})
            result
        end
      end,
      [node()]
    )
  end

  @doc false
  def reset_cache, do: :persistent_term.erase(@cache)

  defp discover do
    req =
      Req.new(url: @feed, retry: false, redirect: false, receive_timeout: 5_000)
      |> Req.merge(Application.get_env(:foreman, :cli_release_req_options, []))

    page(req, 1, nil)
  end

  defp page(req, number, best) do
    case Req.get(req, params: [per_page: 100, page: number]) do
      {:ok, %{status: 200, body: rows} = resp} when is_list(rows) ->
        best = Enum.reduce(rows, best, &choose/2)
        links = Req.Response.get_header(resp, "link") |> Enum.join(",")

        cond do
          String.contains?(links, ~s(rel="next")) -> page(req, number + 1, best)
          best -> {:ok, "v#{best}"}
          true -> :error
        end

      _ ->
        :error
    end
  end

  defp choose(
         %{
           "tag_name" => "v" <> vsn,
           "draft" => false,
           "prerelease" => false,
           "published_at" => published,
           "assets" => assets
         },
         best
       )
       when is_binary(published) and is_list(assets) do
    with {:ok, %Version{pre: [], build: nil} = candidate} <- Version.parse(vsn),
         true <- best == nil or Version.compare(candidate, best) == :gt,
         true <- complete?("v" <> vsn, assets) do
      candidate
    else
      _ -> best
    end
  end

  defp choose(_, best), do: best

  defp complete?(tag, assets) do
    uploaded =
      for %{"state" => "uploaded", "name" => name} <- assets, into: MapSet.new(), do: name

    names = ["SHA256SUMS" | Enum.map(@targets, &(&1 <> ".tar.gz"))]
    Enum.all?(names, &MapSet.member?(uploaded, "foreman-cli-#{tag}-#{&1}"))
  end
end
