defmodule ForemanAgent.Updater do
  @moduledoc """
  Installs a new agent release.

  The signature is checked before anything is downloaded, against the
  public key compiled into this build; it covers the version, the target
  and the tarball's SHA-256, which is checked after download. The release
  unpacks to `<release_root>/releases/<version>`, `previous` records the
  running version, and `current` is swapped atomically. The agent then
  exits and systemd starts the new version. Running environments aren't
  touched: Docker owns them.

  Rolling back: until the new release joins the control plane (`confirm/1`),
  `previous` and an `update-pending` marker stay in place. The systemd
  rollback unit switches back to `previous` when the new release
  crash-loops; the connection's watchdog does it when the release runs but
  hasn't joined after `@rollback_after` seconds (`rollback_due?/2`).

  Updates run one at a time, and an update to the version `current`
  already points at does nothing: the control plane resends the update on
  every reconnect until the box reports the new version.
  """

  alias ForemanProtocol.Auth

  require Logger

  @pending "update-pending"
  @rollback_after 300

  @spec run(map(), ForemanAgent.Config.t(), function(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(payload, config, log, opts \\ []) do
    root = config.release_root

    lock = {{__MODULE__, root}, self()}
    :global.trans(lock, fn -> install(payload, config, log, opts) end, [node()], :infinity)
  end

  defp install(payload, config, log, opts) do
    target = target()
    root = config.release_root

    if current_version(root) == payload.version do
      log.("info", "Agent #{payload.version} is already installed\n")
      {:ok, %{"version" => payload.version, "restart" => running_version() != payload.version}}
    else
      download = Path.join([root, "downloads", "#{payload.version}-#{target}.tar.gz"])

      result =
        with :ok <- verify_signature(payload, target, config.release_public_key),
             :ok <- clear_downloads(root),
             log.("info", "Downloading agent #{payload.version} for #{target}\n"),
             :ok <- fetch(payload.url, download, Keyword.get(opts, :req_options, [])),
             :ok <- verify_digest(download, payload.sha256),
             :ok <- extract(download, Path.join([root, "releases", payload.version])),
             :ok <- swap(root, payload.version) do
          prune_releases(root)
          log.("info", "Installed agent #{payload.version}; restarting\n")
          {:ok, %{"version" => payload.version, "restart" => true}}
        end

      File.rm(download)
      result
    end
  end

  @doc """
  Marks the running release as good: it has joined the control plane, so
  there's nothing to roll back to any more. Only the release `current`
  points at can do that; the old release, still running while it waits
  to restart into the new one, leaves the rollback state to it.
  """
  @spec confirm(ForemanAgent.Config.t(), String.t()) :: :ok
  def confirm(config, running \\ running_version()) do
    root = config.release_root

    if File.exists?(Path.join(root, @pending)) and current_version(root) == running do
      Logger.info("agent #{running_version()} joined; keeping it")
      File.rm(Path.join(root, "previous"))
      File.rm(Path.join(root, @pending))
    end

    :ok
  end

  @doc """
  True when an update hasn't been confirmed, there's a release to go back
  to, and this process (running since `running_since`) has had
  `@rollback_after` seconds to join. Timed from the later of the install
  and the start, so a box shut down right after an update gets the full
  grace period when it boots, however long ago the install was. Only for
  the release `current` points at: the old release waiting to restart
  never rolls back the update it installed.
  """
  @spec rollback_due?(ForemanAgent.Config.t(), integer(), integer(), String.t()) :: boolean()
  def rollback_due?(config, running_since, now, running \\ running_version()) do
    root = config.release_root

    with true <- current_version(root) == running,
         {:ok, contents} <- File.read(Path.join(root, @pending)),
         {installed_at, _} <- Integer.parse(String.trim(contents)),
         {:ok, _} <- :file.read_link(String.to_charlist(Path.join(root, "previous"))) do
      now - max(installed_at, running_since) >= @rollback_after
    else
      _ -> false
    end
  end

  @doc "Switches `current` back to `previous` and forgets the update."
  @spec rollback(ForemanAgent.Config.t()) :: :ok | {:error, term()}
  def rollback(config) do
    root = config.release_root

    with {:ok, previous} <- :file.read_link(String.to_charlist(Path.join(root, "previous"))),
         :ok <- relink(root, "current", to_string(previous)) do
      File.rm(Path.join(root, "previous"))
      File.rm(Path.join(root, @pending))
      :ok
    end
  end

  @doc "This build's release target, e.g. linux-arm64."
  def target do
    arch =
      case :erlang.system_info(:system_architecture)
           |> to_string()
           |> String.split("-")
           |> hd() do
        "aarch64" -> "arm64"
        "x86_64" -> "amd64"
        other -> other
      end

    os =
      case :os.type() do
        {:unix, :linux} -> "linux"
        {:unix, :darwin} -> "darwin"
        {_, other} -> to_string(other)
      end

    "#{os}-#{arch}"
  end

  defp running_version, do: ForemanAgent.Identity.version()

  # The version `current` points at, if it's a release directory.
  defp current_version(root) do
    case :file.read_link(String.to_charlist(Path.join(root, "current"))) do
      {:ok, link} ->
        case Path.split(to_string(link)) do
          ["releases", version] -> version
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp verify_signature(_payload, _target, nil),
    do: {:error, "this agent was built without a release key, so self-update is disabled"}

  defp verify_signature(payload, target, key) do
    case Auth.verify_release(payload.version, target, payload.sha256, payload.signature, key) do
      :ok ->
        :ok

      {:error, :bad_signature} ->
        {:error, "release signature doesn't verify for #{payload.version} (#{target})"}
    end
  end

  # Updates run one at a time, so anything in downloads/ is left over from
  # one that died.
  defp clear_downloads(root) do
    dir = Path.join(root, "downloads")
    File.rm_rf(dir)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "couldn't create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp fetch(url, path, req_options) do
    File.rm(path)

    result =
      Req.get(
        [url: url, into: File.stream!(path), retry: :transient, receive_timeout: 120_000] ++
          req_options
      )

    case result do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "download failed with HTTP #{status}"}
      {:error, exception} -> {:error, "download failed: #{Exception.message(exception)}"}
    end
  rescue
    # Writing the download can fail too (a full disk).
    e in File.Error -> {:error, "download failed: #{Exception.message(e)}"}
  end

  defp verify_digest(path, expected) do
    actual =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected, do: :ok, else: {:error, "downloaded release doesn't match its SHA-256"}
  end

  defp extract(tarball, dest) do
    tar = String.to_charlist(tarball)

    with {:ok, names} <- :erl_tar.table(tar, [:compressed]),
         :ok <- check_names(names) do
      tmp = "#{dest}.partial-#{System.unique_integer([:positive])}"
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)

      case :erl_tar.extract(tar, [:compressed, {:cwd, String.to_charlist(tmp)}]) do
        :ok ->
          File.rm_rf!(dest)
          File.rename!(tmp, dest)
          :ok

        {:error, reason} ->
          File.rm_rf!(tmp)
          {:error, "couldn't unpack the release: #{inspect(reason)}"}
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "couldn't read the release: #{inspect(reason)}"}
    end
  end

  defp check_names(names) do
    unsafe =
      Enum.find(names, fn name ->
        parts = name |> to_string() |> Path.split()
        Path.type(to_string(name)) != :relative or ".." in parts
      end)

    if unsafe, do: {:error, "release contains an unsafe path: #{unsafe}"}, else: :ok
  end

  defp swap(root, version) do
    current = Path.join(root, "current")
    new = "releases/#{version}"

    # `previous` is what to go back to: the last release that joined. So
    # never the release being installed, and not one that's still waiting
    # to join (an update installed over another before a restart).
    unconfirmed? =
      File.exists?(Path.join(root, @pending)) and
        match?({:ok, _}, :file.read_link(String.to_charlist(Path.join(root, "previous"))))

    with false <- unconfirmed?,
         {:ok, previous} <- :file.read_link(String.to_charlist(current)),
         false <- to_string(previous) == new do
      :ok = relink(root, "previous", to_string(previous))
    end

    File.write!(Path.join(root, @pending), Integer.to_string(System.system_time(:second)))
    relink(root, "current", new)
  end

  # Keeps the releases `current` and `previous` point at, and the one
  # running now.
  defp prune_releases(root) do
    keep =
      [running_version()] ++
        for name <- ["current", "previous"],
            {:ok, link} <- [:file.read_link(String.to_charlist(Path.join(root, name)))],
            do: link |> to_string() |> Path.basename()

    releases = Path.join(root, "releases")

    for name <- File.ls!(releases), name not in keep do
      File.rm_rf(Path.join(releases, name))
    end

    :ok
  rescue
    e -> Logger.warning("couldn't prune old releases: #{Exception.message(e)}")
  end

  # A new symlink renamed over the old one, so `current` always exists.
  defp relink(root, name, target) do
    tmp = Path.join(root, ".#{name}.#{System.unique_integer([:positive])}")

    with :ok <- File.ln_s(target, tmp),
         :ok <- File.rename(tmp, Path.join(root, name)) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end
end
