defmodule ForemanAgent.Devcontainer.Features.Control do
  @moduledoc """
  The devcontainers project's control manifest: features it has pulled
  for being harmful (which can't be installed), and advisories against
  versions of others (which are logged). The devcontainer CLI checks it
  before every build; so does the agent.

  A copy is kept for five minutes. When the manifest can't be fetched an
  older copy stands, and without one nothing is disallowed: a registry
  being reachable and this site not shouldn't stop an environment.
  """

  @url "https://containers.dev/static/devcontainer-control-manifest.json"
  @fresh_seconds 300
  @max_bytes 4 * 1024 * 1024

  @type t :: %{disallowed: [map()], advisories: [map()]}

  @spec load(Path.t(), (-> {:ok, binary()} | {:error, term()})) :: t()
  def load(cache_path, fetch \\ &fetch/0) do
    cached = cached(cache_path)

    case cached do
      {manifest, age} when age < @fresh_seconds ->
        manifest

      _ ->
        case fetch.() do
          {:ok, body} ->
            manifest = parse(body)
            File.mkdir_p(Path.dirname(cache_path))
            tmp = "#{cache_path}.#{System.unique_integer([:positive])}"

            with :ok <- File.write(tmp, body), do: File.rename(tmp, cache_path)
            manifest

          {:error, _} ->
            case cached do
              {manifest, _age} ->
                File.touch(cache_path)
                manifest

              nil ->
                empty()
            end
        end
    end
  end

  defp cached(path) do
    with {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, body} <- File.read(path) do
      {parse(body), System.os_time(:second) - mtime}
    else
      _ -> nil
    end
  end

  defp fetch do
    request =
      Req.new(
        url: @url,
        headers: [{"user-agent", "devcontainers-vscode"}, {"accept", "application/json"}],
        retry: false,
        decode_body: false,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000]
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} when byte_size(body) <= @max_bytes ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp empty, do: %{disallowed: [], advisories: []}

  defp parse(body) do
    case JSON.decode(body) do
      {:ok, %{} = manifest} ->
        %{
          disallowed:
            for(
              %{"featureIdPrefix" => prefix} = entry <- list(manifest["disallowedFeatures"]),
              is_binary(prefix),
              do: entry
            ),
          advisories:
            for(
              %{
                "featureId" => id,
                "introducedInVersion" => from,
                "fixedInVersion" => to,
                "description" => text
              } = entry <-
                list(manifest["featureAdvisories"]),
              Enum.all?([id, from, to, text], &is_binary/1),
              do: entry
            )
        }

      _ ->
        empty()
    end
  end

  defp list(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list(_value), do: []

  @doc "The first of `ids` (as a devcontainer.json names features) that's disallowed, if any."
  @spec disallowed(t(), [String.t()]) ::
          %{id: String.t(), documentation_url: String.t() | nil} | nil
  def disallowed(manifest, ids) do
    Enum.find_value(ids, fn id ->
      Enum.find_value(manifest.disallowed, fn %{"featureIdPrefix" => prefix} = entry ->
        if String.starts_with?(id, prefix) and
             (byte_size(id) == byte_size(prefix) or
                binary_part(id, byte_size(prefix), 1) in ["/", ":", "@"]),
           do: %{id: id, documentation_url: entry["documentationURL"]}
      end)
    end)
  end

  @doc "The registry features among `sets` whose version an advisory covers."
  @spec advisories(t(), [map()]) :: [%{id: String.t(), version: String.t(), advisories: [map()]}]
  def advisories(manifest, sets) do
    for %{source: %{type: :oci, ref: ref}, metadata: %{"version" => version}} <- sets,
        id = "#{ref.registry}/#{ref.path}",
        parsed = version(version),
        found =
          Enum.filter(manifest.advisories, fn advisory ->
            from = version(advisory["introducedInVersion"])
            to = version(advisory["fixedInVersion"])
            advisory["featureId"] == id && from && to && parsed >= from && parsed < to
          end),
        found != [] do
      %{id: id, version: version, advisories: found}
    end
    |> Enum.sort_by(& &1.id)
  end

  @doc "Advisories as the log shows them."
  @spec describe([map()]) :: String.t()
  def describe(found) do
    lines =
      for %{id: id, version: version, advisories: advisories} <- found, advisory <- advisories do
        see =
          if advisory["documentationURL"], do: ", see #{advisory["documentationURL"]}", else: ""

        "- #{id}:#{version}: #{advisory["description"]} (introduced in #{advisory["introducedInVersion"]}, " <>
          "fixed in #{advisory["fixedInVersion"]}#{see})\n"
      end

    "Feature advisories:\n" <>
      Enum.join(lines) <> "Update these features to versions with the fixes.\n"
  end

  # A version as numbers that compare: 1.2 is [1, 2, 0].
  defp version(text) when is_binary(text) do
    case Regex.run(~r/^v?(\d+)(?:\.(\d+)(?:\.(\d+))?)?/, text) do
      nil ->
        nil

      [_ | parts] ->
        parts
        |> Enum.map(&String.to_integer/1)
        |> then(&(&1 ++ List.duplicate(0, 3 - length(&1))))
    end
  end

  defp version(_text), do: nil
end
