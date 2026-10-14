defmodule ForemanAgent.Updater do
  @moduledoc """
  Installs a new agent release.

  The signature is checked before anything is downloaded, against the
  public key compiled into this build; it covers the version, the target
  and the tarball's SHA-256, which is checked after download. The release
  unpacks to `<release_root>/releases/<version>`, `previous` records the
  running version for the systemd rollback unit, and `current` is swapped
  atomically. The agent then exits and systemd starts the new version.
  Running environments aren't touched: Docker owns them.
  """

  alias ForemanProtocol.Auth

  @spec run(map(), ForemanAgent.Config.t(), function(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(payload, config, log, opts \\ []) do
    target = target()
    root = config.release_root
    dest = Path.join([root, "releases", payload.version])

    with :ok <- verify_signature(payload, target, config.release_public_key),
         :ok <- File.mkdir_p(Path.join(root, "downloads")),
         download = Path.join([root, "downloads", "#{payload.version}-#{target}.tar.gz"]),
         log.("info", "Downloading agent #{payload.version} for #{target}\n"),
         :ok <- fetch(payload.url, download, Keyword.get(opts, :req_options, [])),
         :ok <- verify_digest(download, payload.sha256),
         :ok <- extract(download, dest),
         :ok <- swap(root, payload.version) do
      File.rm(download)
      log.("info", "Installed agent #{payload.version}; restarting\n")
      {:ok, %{"version" => payload.version, "restart" => true}}
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
      tmp = dest <> ".partial"
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

    with {:ok, previous} <- :file.read_link(String.to_charlist(current)) do
      :ok = relink(root, "previous", to_string(previous))
    end

    relink(root, "current", "releases/#{version}")
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
