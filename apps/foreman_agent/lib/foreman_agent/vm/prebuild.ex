defmodule ForemanAgent.VM.Prebuild do
  @moduledoc """
  Prebuilds: an environment's data disk with the repo cloned and its
  devcontainer built, made once so new environments start from it.

  `box.prebuild` makes one in a VM of its own, the way an environment is
  made: `env.create` in the guest under the prebuild's id, with a GitHub
  token to clone with and nobody's secrets. Tailscale gets no key, so
  nothing joins the tailnet. The token lives on the guest's tmpfs, so it
  goes when the guest powers off, before the disk is kept. Then the data
  disk is kept as `<prebuilds_root>/<id>/data.raw`.

  An `env.create` that names the prebuild starts from a copy of that disk
  (a reflink where the filesystem has them, see `ForemanAgent.VM.Env`),
  and the agent in the VM takes over the prebuild's clone and images
  (`ForemanAgent.Env`), so `devcontainer up` makes the environment's
  containers without pulling or building what the prebuild already did.

  The VM a prebuild is built in isn't an environment: the box leaves it
  out of what it reports (`ForemanAgent.VM.list/2`), and `box.gc` removes
  one nothing is building any more.
  """

  alias ForemanAgent.VM
  alias ForemanAgent.VM.{Env, Links, Machine}
  alias ForemanProtocol.Command

  @doc "Where a prebuild's disk and record live."
  def dir(config, id), do: Path.join(config.prebuilds_root, id)
  def disk(config, id), do: Path.join(dir(config, id), "data.raw")

  @doc "Whether this box has the prebuild."
  def exists?(config, id), do: File.regular?(disk(config, id))

  @doc "The compose project (and VM) name a prebuild is built under."
  def slug(id), do: "prebuild-" <> String.slice(id, 0, 8)

  @spec build(Command.t(), (String.t(), String.t() -> any()), map()) ::
          {:ok, map()} | {:error, String.t()}
  def build(%Command{payload: p} = cmd, log, ctx) do
    config = ctx.config
    # A guest that never finishes the build doesn't keep its VM forever.
    ctx = Map.put(ctx, :relay_timeout, config.prebuild_timeout)
    id = p.prebuild_id
    paths = VM.paths(config, id)

    # Recorded before anything boots, so the box never reports it as an
    # environment, and box.gc knows which operation it belongs to.
    File.mkdir_p!(paths.dir)
    File.chmod!(paths.dir, 0o700)
    VM.write_meta(config, id, %{"slug" => slug(id), "kind" => "prebuild", "op_id" => cmd.op_id})

    log.("info", "Building a prebuild of #{p.repo} (#{p.branch})\n")

    # The VM goes however the build ends, a crash included.
    try do
      with {:ok, create} <- create_command(cmd),
           {:ok, up} <- Env.run(create, log, ctx),
           :ok <- stop(id, log, ctx),
           :ok <- keep_disk(ctx, id, p) do
        {:ok,
         %{
           "prebuild_id" => id,
           "size_mb" => div(used_bytes(disk(config, id)), 1_048_576),
           "feature_version" => up["feature_version"]
         }}
      end
      |> normalize()
    catch
      kind, reason ->
        discard(config, id)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result -> with :ok <- discard(config, id), do: result
    end
  end

  # The same op id: a resend after a reconnect runs it once in the guest.
  defp create_command(%Command{payload: p, op_id: op_id}) do
    Command.new(
      "env.create",
      %{
        env_id: p.prebuild_id,
        slug: slug(p.prebuild_id),
        repo: p.repo,
        clone_url: p.clone_url,
        branch: p.branch,
        config_path: p.config_path,
        files: p.files,
        tailscale: p.tailscale,
        limits: Map.get(p, :limits, %{}),
        prebuild: true
      }
      |> put_present(:registry_auth, Map.get(p, :registry_auth)),
      op_id: op_id
    )
  end

  @doc "Removes a prebuild from the box."
  @spec delete(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def delete(id, ctx) do
    with :ok <- VM.remove_tree(dir(ctx.config, id)), do: {:ok, %{}}
  end

  @doc """
  Removes what building a prebuild left: the VM, its tap and address, its
  root disk and the files the box kept for it. A kept prebuild's disk is
  elsewhere already.
  """
  def discard(config, id) do
    Links.stop(id)
    machine = Machine.impl(config)

    with :ok <- machine.release(id, config),
         :ok <- VM.remove_tree(Path.join(config.secrets_root, id)),
         :ok <- VM.remove_tree(VM.paths(config, id).dir) do
      VM.remove_tree(VM.paths(config, id).meta)
    end
  end

  defp stop(id, log, ctx) do
    {:ok, stop} = Command.new("env.stop", %{env_id: id, slug: slug(id)})

    case Env.run(stop, log, ctx) do
      {:ok, %{"forced_off" => true}} ->
        {:error, "the prebuild's VM didn't shut down, so its disk isn't kept"}

      {:ok, _} ->
        :ok

      {:error, message} ->
        {:error, "couldn't stop the prebuild's VM: #{message}"}

      {:error, message, _} ->
        {:error, "couldn't stop the prebuild's VM: #{message}"}
    end
  end

  defp keep_disk(ctx, id, p) do
    config = ctx.config
    target = dir(config, id)
    stage = Path.join(target, ".publish-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))
    File.mkdir_p!(target)
    File.chmod!(target, 0o700)
    File.mkdir!(stage)

    try do
      File.chmod!(stage, 0o700)

      File.write!(
        Path.join(stage, "prebuild.json"),
        JSON.encode!(%{
          "repo" => p.repo,
          "branch" => p.branch,
          "config_path" => p.config_path,
          "built_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
      )

      # Consumers test for data.raw. Publish it last, after the metadata
      # and any cross-device copy are complete on the destination mount.
      with :ok <- stage_disk(VM.paths(config, id).data, Path.join(stage, "data.raw"), ctx),
           :ok <-
             File.rename(Path.join(stage, "prebuild.json"), Path.join(target, "prebuild.json")) do
        File.rename(Path.join(stage, "data.raw"), disk(config, id))
      end
    after
      File.rm_rf!(stage)
    end
  end

  defp stage_disk(source, dest, ctx) do
    with {:ok, %{type: :regular}} <- File.lstat(source),
         {:error, :exdev} <- File.rename(source, dest) do
      case ctx.runner.run(
             "cp",
             ["--no-dereference", "--reflink=auto", "--sparse=always", source, dest],
             timeout: 600_000
           ) do
        {:ok, %{status: 0}} ->
          if match?({:ok, %{type: :regular}}, File.lstat(dest)),
            do: :ok,
            else: {:error, "invalid prebuild disk"}

        other ->
          {:error, "couldn't copy the prebuild disk: #{inspect(other)}"}
      end
    else
      {:ok, _} -> {:error, "invalid prebuild disk"}
      result -> result
    end
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, message}) when is_binary(message), do: {:error, message}
  defp normalize({:error, message, _result}), do: {:error, message}
  defp normalize({:error, other}), do: {:error, "couldn't build the prebuild: #{inspect(other)}"}

  # What the sparse disk takes on the box, not its size.
  defp used_bytes(path) do
    case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> hd() |> String.to_integer() |> Kernel.*(1024)
      _ -> File.stat!(path).size
    end
  rescue
    _ -> 0
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
