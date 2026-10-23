defmodule Foreman.Updates do
  @moduledoc """
  New Foreman releases, and updating to them from the UI.

  `check/0` asks GitHub for the highest published `vX.Y.Z` release and
  caches it; `Foreman.Jobs.CheckForUpdates` runs it every five minutes.

  The control plane can't replace its own container, so updating is the
  host's job: `foreman-update` (priv/updater), run by a systemd path unit
  as root. The two share a directory (`update_dir`, mounted into the
  container):

    * `request/` is the container's. `request/0` writes the version to
      `request/version`, and that is all the container can say: the host
      takes a newer `X.Y.Z` from its configured image repository, or
      nothing.
    * `status/` is the host's, read-only in here: `updater` exists once
      the updater is installed, and `state.json` describes its last run.
  """

  require Logger

  alias Foreman.{Audit, Scope}

  @cache {__MODULE__, :latest}
  @tag ~r/\Av(\d+\.\d+\.\d+)\z/
  # The updater reports at least every step; a run silent this long died.
  @stale_after 30 * 60

  @doc "The highest published release, as last checked, or nil."
  def latest, do: :persistent_term.get(@cache, nil)

  @doc "The latest release if it's newer than this control plane, or nil."
  def available do
    case latest() do
      %{version: version} = release when is_binary(version) ->
        if newer?(version, Foreman.Config.version()), do: release

      _ ->
        nil
    end
  end

  @doc false
  def reset, do: :persistent_term.erase(@cache)

  def enabled?, do: Application.get_env(:foreman, :update_check, true)

  def repo, do: Application.get_env(:foreman, :update_repo, "ntodd/foreman")

  def newer?(a, b), do: Version.compare(a, b) == :gt

  @doc "Asks GitHub for the latest release and caches it."
  def check do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case fetch_releases() do
      {:ok, releases} ->
        release =
          releases
          |> Enum.flat_map(&published/1)
          |> Enum.max_by(& &1.version, Version, fn -> nil end)

        cache(release && Map.merge(release, %{checked_at: now, error: nil}))
        {:ok, release}

      {:error, reason} ->
        message = error_message(reason)
        Logger.warning("couldn't check for Foreman releases: #{message}")

        cache(
          Map.merge(latest() || %{version: nil, url: nil}, %{checked_at: now, error: message})
        )

        {:error, reason}
    end
  end

  # Writes only on a change: every write to a persistent term is a global GC.
  defp cache(value), do: if(value != latest(), do: :persistent_term.put(@cache, value))

  defp fetch_releases do
    Req.new(
      base_url: "https://api.github.com",
      headers: [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "foreman"}
      ],
      params: [per_page: 30],
      retry: :transient,
      max_retries: 2
    )
    |> Req.merge(Application.get_env(:foreman, :updates_req_options, []))
    |> Req.get(url: "/repos/#{repo()}/releases")
    |> case do
      {:ok, %{status: 200, body: releases}} when is_list(releases) -> {:ok, releases}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp published(%{"draft" => false, "prerelease" => false, "tag_name" => tag} = release) do
    case Regex.run(@tag, tag) do
      [_, version] -> [%{version: version, url: release["html_url"]}]
      nil -> []
    end
  end

  defp published(_), do: []

  defp error_message({:status, status}), do: "GitHub answered #{status}"
  defp error_message(%{__exception__: true} = e), do: Exception.message(e)
  defp error_message(other), do: inspect(other)

  @doc """
  The host's updater: whether it's installed, and its last run, if any.
  A request it hasn't picked up yet shows as `"pending"`, and a run that
  stopped reporting as `"stale"`.
  """
  def updater do
    status = Path.join(dir(), "status")

    if File.regular?(Path.join(status, "updater")) do
      Map.merge(%{installed: true}, run(status))
    else
      %{installed: false, state: nil}
    end
  end

  defp run(status) do
    case requested() do
      nil -> last_run(status)
      version -> %{state: "pending", to: version, from: nil, message: nil, at: nil}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Every path is under update_dir, from the deployment's config; nothing
  # a request sends reaches one.
  defp last_run(status) do
    with {:ok, body} <- File.read(Path.join(status, "state.json")),
         {:ok, %{} = state} <- JSON.decode(body) do
      at = parse_time(state["at"])

      %{
        state: stale(state["state"], at),
        from: state["from"],
        to: state["to"],
        message: state["message"],
        at: at
      }
    else
      _ -> %{state: nil, from: nil, to: nil, message: nil, at: nil}
    end
  end

  defp stale("running", at) do
    if at && DateTime.diff(DateTime.utc_now(), at) < @stale_after, do: "running", else: "stale"
  end

  defp stale(state, _at), do: state

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # sobelow_skip ["Traversal.FileModule"]
  # Every path is under update_dir, from the deployment's config; nothing
  # a request sends reaches one.
  defp requested do
    case File.read(request_path()) do
      {:ok, body} -> String.trim(body)
      _ -> nil
    end
  end

  @doc """
  Asks the host to update to `version`, which must be the release the
  last check found newer than this one.
  """
  def request(%Scope{} = scope, version) do
    updater = updater()

    cond do
      not Scope.admin?(scope) -> {:error, :forbidden}
      not match?(%{version: ^version}, available()) -> {:error, :not_available}
      not updater.installed -> {:error, :no_updater}
      updater.state in ["pending", "running"] -> {:error, :in_progress}
      true -> write_request(scope, version)
    end
  end

  # Renamed into place, so the host never reads half a version. The path
  # unit only watches `version`.
  # sobelow_skip ["Traversal.FileModule"]
  # Every path is under update_dir, from the deployment's config; nothing
  # a request sends reaches one.
  defp write_request(scope, version) do
    tmp = Path.join(Path.dirname(request_path()), ".version.tmp")

    with :ok <- File.write(tmp, version <> "\n"),
         :ok <- File.rename(tmp, request_path()) do
      Audit.log(scope, "foreman.update", nil, %{
        "from" => Foreman.Config.version(),
        "to" => version
      })

      :ok
    end
  end

  defp dir, do: Application.get_env(:foreman, :update_dir, "/var/lib/foreman-update")
  defp request_path, do: Path.join([dir(), "request", "version"])
end
