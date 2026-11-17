defmodule ForemanAgent.VM.Image do
  @moduledoc """
  The disks every environment VM shares: the guest system image and the
  agent disk.

  The guest image is a tarball (`guest/build.sh`) the agent downloads
  from the URL it was built with and checks against the SHA-256 it was
  built with, so it only boots what its release names. It's unpacked to
  `<guest_root>/<sha256>/`: the kernel, and the root disk, written sparse.

  The agent disk is an ext4 image of this agent's own release, made once
  per version with `mkfs.ext4 -d`. The guest mounts it read-only and runs
  the agent from it, so the agent in every VM is the box's.
  """

  alias ForemanAgent.{Config, Identity}

  @block 65_536
  @zero_block :binary.copy(<<0>>, @block)

  @doc "Makes sure the guest image is unpacked; returns its SHA-256 and directory."
  @spec ensure_guest(Config.t(), (String.t(), String.t() -> any())) ::
          {:ok, %{digest: String.t(), dir: Path.t()}} | {:error, String.t()}
  def ensure_guest(config, log) do
    with {:ok, url, digest} <- guest_source(config) do
      dir = Path.join(config.guest_root, digest)
      fetch = fn -> ready_guest(dir, digest) || fetch_guest(config, url, digest, dir, log) end
      # One download at a time, however many environments want it.
      ready_guest(dir, digest) || :global.trans({{__MODULE__, :guest}, self()}, fetch)
    end
  end

  defp ready_guest(dir, digest) do
    if File.exists?(Path.join(dir, ".ready")), do: {:ok, %{digest: digest, dir: dir}}
  end

  defp guest_source(%Config{guest_url: url, guest_sha256: sha})
       when is_binary(url) and is_binary(sha) do
    if sha =~ ~r/\A[0-9a-f]{64}\z/,
      do: {:ok, url, sha},
      else: {:error, "the guest image's SHA-256 is malformed"}
  end

  defp guest_source(_config),
    do:
      {:error,
       "this agent doesn't name a guest image for environment VMs (built without one, or not for amd64)"}

  defp fetch_guest(config, url, digest, dir, log) do
    File.mkdir_p!(config.guest_root)
    work = Path.join(config.guest_root, ".#{digest}.#{System.unique_integer([:positive])}")
    File.rm_rf!(work)
    File.mkdir_p!(work)
    tarball = Path.join(work, "guest.tar")

    try do
      log.("info", "Downloading the environment image\n")

      with :ok <- download(url, tarball),
           :ok <- check_digest(tarball, digest),
           :ok <- unpack(tarball, work) do
        File.rm!(tarball)
        File.write!(Path.join(work, ".ready"), digest)
        File.rm_rf!(dir)
        File.rename!(work, dir)
        log.("info", "Environment image ready\n")
        {:ok, %{digest: digest, dir: dir}}
      end
    after
      File.rm_rf(work)
    end
  end

  defp download("file://" <> path, dest) do
    case File.cp(path, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, "couldn't read the guest image at #{path}: #{inspect(reason)}"}
    end
  end

  defp download("https://" <> _ = url, dest) do
    case Req.get(url, into: File.stream!(dest), receive_timeout: 600_000, retry: :transient) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "downloading the guest image: HTTP #{status}"}

      {:error, reason} ->
        {:error, "downloading the guest image: #{Exception.message(reason)}"}
    end
  end

  defp download(_url, _dest), do: {:error, "the guest image's URL has to be https:// or file://"}

  defp check_digest(path, digest) do
    actual =
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == digest,
      do: :ok,
      else: {:error, "the guest image doesn't match its SHA-256 (got #{actual})"}
  end

  # Only the three files the image is made of, and only as plain files.
  defp unpack(tarball, work) do
    wanted = [~c"manifest.json", ~c"vmlinuz", ~c"root.raw.zst"]

    with {:ok, entries} <- :erl_tar.table(String.to_charlist(tarball), [:verbose]),
         true <- Enum.all?(entries, &plain_entry?(&1, wanted)) || {:error, :unexpected_entry},
         :ok <- :erl_tar.extract(String.to_charlist(tarball), cwd: String.to_charlist(work)),
         :ok <- unzstd(Path.join(work, "root.raw.zst"), Path.join(work, "root.raw")) do
      File.rm!(Path.join(work, "root.raw.zst"))
      File.chmod!(Path.join(work, "vmlinuz"), 0o644)
      File.chmod!(Path.join(work, "root.raw"), 0o644)
      :ok
    else
      {:error, reason} -> {:error, "couldn't unpack the guest image: #{inspect(reason)}"}
    end
  end

  defp plain_entry?({name, :regular, _size, _mtime, _mode, _uid, _gid}, wanted),
    do: name in wanted

  defp plain_entry?(_entry, _wanted), do: false

  @doc """
  Decompresses a zstd file, leaving the all-zero parts of the output as
  holes: the root disk is mostly empty space.
  """
  @spec unzstd(Path.t(), Path.t()) :: :ok | {:error, term()}
  def unzstd(src, dest) do
    _ = File.rm(dest)
    {:ok, ctx} = :zstd.context(:decompress)
    {:ok, fd} = :file.open(dest, [:write, :raw, :binary])

    try do
      pos =
        src
        |> File.stream!(4 * 1_048_576)
        |> Enum.reduce(0, fn chunk, pos -> feed(ctx, chunk, fd, pos) end)

      {:done, rest} = :zstd.finish(ctx, <<>>)
      pos = write_sparse(fd, pos, IO.iodata_to_binary(rest))
      {:ok, _} = :file.position(fd, pos)
      :file.truncate(fd)
    rescue
      e -> {:error, Exception.message(e)}
    after
      :file.close(fd)
      :zstd.close(ctx)
    end
  end

  defp feed(ctx, data, fd, pos) do
    case :zstd.stream(ctx, data) do
      {:continue, out} ->
        write_sparse(fd, pos, IO.iodata_to_binary(out))

      {:continue, rest, out} ->
        pos = write_sparse(fd, pos, IO.iodata_to_binary(out))
        if IO.iodata_length(rest) > 0, do: feed(ctx, rest, fd, pos), else: pos

      {:done, out} ->
        write_sparse(fd, pos, IO.iodata_to_binary(out))
    end
  end

  defp write_sparse(_fd, pos, <<>>), do: pos

  defp write_sparse(fd, pos, <<block::binary-size(@block), rest::binary>>) do
    write_block(fd, pos, block)
    write_sparse(fd, pos + @block, rest)
  end

  defp write_sparse(fd, pos, block) do
    write_block(fd, pos, block)
    pos + byte_size(block)
  end

  defp write_block(_fd, _pos, @zero_block), do: :ok

  defp write_block(fd, pos, block) do
    if block == :binary.copy(<<0>>, byte_size(block)),
      do: :ok,
      else: :ok = :file.pwrite(fd, pos, block)
  end

  @doc """
  Makes sure this agent's release is on an agent disk; returns its version
  and path. Only an agent running from a release has one to give.
  """
  @spec ensure_agent_disk(Config.t(), module(), (String.t(), String.t() -> any())) ::
          {:ok, %{version: String.t(), path: Path.t()}} | {:error, String.t()}
  def ensure_agent_disk(config, runner, log, release_dir \\ :code.root_dir()) do
    version = Identity.version()
    path = Path.join(config.agent_disks, "#{version}.img")
    release_dir = to_string(release_dir)

    cond do
      File.regular?(path) ->
        {:ok, %{version: version, path: path}}

      not File.exists?(Path.join(release_dir, "bin/foreman_agent")) ->
        {:error, "environment VMs need the agent to run from its release"}

      true ->
        :global.trans({{__MODULE__, :agent_disk}, self()}, fn ->
          if File.regular?(path),
            do: {:ok, %{version: version, path: path}},
            else: make_agent_disk(config, runner, release_dir, version, path, log)
        end)
    end
  end

  defp make_agent_disk(config, runner, release_dir, version, path, log) do
    File.mkdir_p!(config.agent_disks)
    # A dot-name, which box.gc leaves alone while it's being made.
    tmp = Path.join(Path.dirname(path), "." <> Path.basename(path) <> ".tmp")
    _ = File.rm(tmp)
    size_mb = div(tree_size(release_dir) * 13, 10 * 1_048_576) + 64
    log.("info", "Making the agent disk for #{version}\n")

    args = ["-q", "-F", "-L", "fm-agent", "-d", release_dir, tmp, "#{size_mb}M"]

    case runner.run("mkfs.ext4", args, timeout: 120_000) do
      {:ok, %{status: 0}} ->
        File.rename!(tmp, path)
        {:ok, %{version: version, path: path}}

      {:ok, %{output: output}} ->
        _ = File.rm(tmp)
        {:error, "couldn't make the agent disk: #{String.slice(output, -500, 500)}"}

      {:error, reason} ->
        {:error, "couldn't make the agent disk: #{inspect(reason)}"}
    end
  end

  defp tree_size(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        dir |> File.ls!() |> Enum.reduce(4096, &(&2 + tree_size(Path.join(dir, &1))))

      {:ok, %File.Stat{size: size}} ->
        size + 4096

      _ ->
        0
    end
  end
end
