defmodule ForemanAgent.Devcontainer.Features do
  @moduledoc """
  A devcontainer's features, made ready to install: each one found (in an
  OCI registry, in the repo's `.devcontainer` folder, or at a URL), put in
  install order with what it depends on, and its files laid out in a
  build folder, `<id>_<n>` by install order.

  A feature set is one feature to install:

      %{
        source: %{type: :oci | :file_path | :tarball, user_feature_id: ..., ...},
        id: "go",
        value: true | "1.22" | %{"version" => "1.22"},   # what the config gave it
        metadata: %{...},        # its devcontainer-feature.json
        order: %{"options" => [...], "containerEnv" => [...]},   # those objects' keys, as written
        consecutive_id: "go_0",
        cache_path: "<build folder>/go_0",
        computed_digest: "sha256:..." | nil
      }

  Features of the first format (a `devcontainer-features.json` for several)
  and ones published as GitHub releases aren't supported; the devcontainer
  CLI has long called both deprecated.
  """

  alias ForemanAgent.Devcontainer.Features.{Order, Ref, Registry}
  alias ForemanAgent.SafeFS
  alias ForemanProtocol.Jsonc

  @feature_file "devcontainer-feature.json"
  @max_feature_file 1_048_576
  @max_archive 256 * 1024 * 1024
  @registry "ghcr.io/devcontainers/features"

  # Features the first devcontainers shipped with, by the names they had then.
  @migrated ~w(aws-cli azure-cli desktop-lite docker-in-docker docker-from-docker dotnet git git-lfs
               github-cli java kubectl-helm-minikube node powershell python ruby rust sshd terraform)
  @renamed %{"golang" => "go", "common" => "common-utils"}
  @folded %{
    "gradle" => {"java", %{"installGradle" => true}},
    "maven" => {"java", %{"installMaven" => true}},
    "jupyterlab" => {"python", %{"installJupyterlab" => true}}
  }

  @type set :: map()

  @doc """
  Makes the features of `config` (a devcontainer.json) and `additional`
  (id => options) ready in the build folder `dst`. Options:

    * `:workspace` - the repo's folder
    * `:config_path` - the devcontainer.json's path, which local features are relative to
    * `:registry` - a `Features.Registry` client
    * `:local_roots` - folders in the workspace, besides `.devcontainer`, that
      a local feature may be in
    * `:lockfile` - a decoded `devcontainer-lock.json`, to pin what's pulled
    * `:github_token` - sent to GitHub for a feature at a URL there
    * `:deadline` - when to give up, in monotonic milliseconds
    * `:log` - `fn text -> any end`
  """
  @spec prepare(map(), map(), Path.t(), keyword()) :: {:ok, [set()]} | {:error, String.t()}
  def prepare(config, additional, dst, opts) do
    case user_features(config["features"], additional) do
      [] ->
        {:ok, []}

      features ->
        state = %{
          opts: opts,
          log: opts[:log] || fn _ -> :ok end,
          lockfile: opts[:lockfile] || %{},
          dst: dst
        }

        with {:ok, worklist} <- graph(features, state),
             {:ok, worklist} <- prioritize(worklist, config["overrideFeatureInstallOrder"], state),
             {:ok, ordered} <- order(worklist) do
          fetch(Enum.map(ordered, & &1.set), state)
        end
    end
  catch
    {:feature_error, message} -> {:error, message}
  end

  @doc """
  The features to install, as `{id, options}`: the config's, then the
  additional ones the config doesn't have itself.
  """
  @spec user_features(map() | nil, map() | nil) :: [{String.t(), term()}]
  def user_features(features, additional) do
    features = if is_map(features), do: features, else: %{}
    additional = if is_map(additional), do: Map.drop(additional, Map.keys(features)), else: %{}

    fold(Enum.to_list(features) ++ Enum.to_list(additional))
  end

  # gradle, maven and jupyterlab became options of java and python.
  defp fold(features) do
    {folded, kept} = Enum.split_with(features, fn {id, _} -> is_map_key(@folded, id) end)

    Enum.reduce(folded, kept, fn {id, _options}, kept ->
      {into, with_options} = @folded[id]
      qualified = "#{@registry}/#{into}"

      case Enum.find_index(kept, fn {kept_id, _} ->
             kept_id == into or kept_id == qualified or
               String.starts_with?(kept_id, qualified <> ":")
           end) do
        nil ->
          kept ++ [{"#{qualified}:1", with_options}]

        index ->
          List.update_at(kept, index, fn {kept_id, options} ->
            {kept_id, Map.merge(as_options(options), with_options)}
          end)
      end
    end)
  end

  defp as_options(options) when is_map(options), do: options
  defp as_options(version) when is_binary(version), do: %{"version" => version}
  defp as_options(_value), do: %{}

  @doc "Where a feature that went by a short name is published now."
  @spec modern_id(String.t()) :: String.t()
  def modern_id(id) when id in @migrated, do: "#{@registry}/#{id}:1"
  def modern_id(id) when is_map_key(@renamed, id), do: "#{@registry}/#{@renamed[id]}:1"
  def modern_id(id), do: id

  # -- the graph -----------------------------------------------------------

  # Every feature to install, with what it depends on found too.
  defp graph(features, state) do
    roots = for {id, options} <- features, do: new_node(id, options)
    {:ok, walk(roots, [], state)}
  end

  defp new_node(id, options) do
    %{
      user_feature_id: id,
      options: options,
      set: nil,
      depends_on: [],
      installs_after: [],
      aliases: nil,
      priority: 0
    }
  end

  defp walk([], done, _state), do: Enum.reverse(done)

  defp walk([node | rest], done, state) do
    state.log.("Resolving the feature #{node.user_feature_id}")
    node = resolve(node, state)

    if Enum.any?(done, &Order.equal?(&1, node)) do
      walk(rest, done, state)
    else
      metadata = node.set.metadata

      depends_on =
        for {id, options} <- object(metadata["dependsOn"]),
            do: resolve(new_node(id, options), state)

      installs_after =
        for id <- list(metadata["installsAfter"]), soft = soft_dependency(id, state), do: soft

      node = %{node | depends_on: depends_on, installs_after: installs_after}

      walk(
        rest ++ Enum.map(depends_on, &%{&1 | depends_on: [], installs_after: []}),
        [node | done],
        state
      )
    end
  end

  # A node with its feature found, and its metadata where that says what
  # it depends on.
  defp resolve(node, state) do
    in_time!(state, node.user_feature_id)
    set = identify(node.user_feature_id, node.options, state)
    set = %{set | metadata: Map.merge(set.metadata, early_metadata(set, state))}
    %{node | set: %{set | id: own_id(set)}, aliases: aliases(set.metadata)}
  end

  # What a feature calls itself. It names the folder the feature is laid
  # out in (which is emptied first) and goes into the Dockerfile, so it
  # has to be a plain name, whatever the feature's file says.
  defp own_id(set) do
    id = Map.get(set.metadata, "id", set.id)

    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9._-]*\z/, id),
      do: id,
      else:
        fail(
          "the feature #{set.source.user_feature_id} calls itself #{inspect(id)}, which isn't a name a feature can have"
        )
  end

  # Pulling features has no command to time out, so each step checks.
  defp in_time!(state, id) do
    deadline = state.opts[:deadline]

    if deadline && System.monotonic_time(:millisecond) >= deadline,
      do: fail("there was no time left to get the feature #{id}")
  end

  defp aliases(metadata) do
    case metadata["id"] do
      id when is_binary(id) -> [metadata["currentId"] || id | list(metadata["legacyIds"])]
      _ -> nil
    end
  end

  # A feature another only wants to come after. It's never installed for
  # that, so one that can't be found just can't be waited for.
  defp soft_dependency(id, state) do
    resolve(new_node(id, %{}), state)
  catch
    {:feature_error, _message} ->
      case Ref.parse(modern_id(id)) do
        {:ok, ref} ->
          %{
            new_node(id, %{})
            | set: %{source: %{type: :oci, ref: ref, manifest_digest: nil, user_feature_id: id}}
          }

        :error ->
          state.log.("Not waiting for #{id}, which isn't a feature Foreman can find")
          nil
      end
  end

  defp prioritize(worklist, nil, _state), do: {:ok, worklist}

  defp prioritize(worklist, overrides, state) when is_list(overrides) do
    overrides =
      for id <- overrides, is_binary(id), do: %{new_node(id, %{}) | set: identify(id, %{}, state)}

    {:ok, Order.prioritize(worklist, overrides)}
  end

  defp prioritize(_worklist, _overrides, _state),
    do: {:error, "overrideFeatureInstallOrder must be a list of features"}

  defp order(worklist) do
    case Order.install_order(worklist) do
      {:ok, ordered} ->
        {:ok, ordered}

      {:error, :circular, ids} ->
        {:error,
         "the features #{Enum.join(ids, ", ")} depend on each other, or on a feature that can't be installed"}
    end
  end

  # -- finding a feature ---------------------------------------------------

  defp identify(original, options, state) do
    id = modern_id(original)

    cond do
      not String.contains?(id, ["/", "\\"]) ->
        fail(
          "the feature #{original} isn't one Foreman can find. See https://containers.dev/features for " <>
            "what replaced it; a feature in the repo is named by its path, starting with ./"
        )

      String.starts_with?(id, "https://") ->
        tarball(id, original, options)

      String.starts_with?(id, ["./", "../", "/"]) ->
        local(id, original, options, state)

      true ->
        oci(id, original, options, state)
    end
  end

  defp new_set(source, id, options, metadata \\ %{}) do
    %{
      source: source,
      id: id,
      value: options,
      metadata: metadata,
      order: %{},
      consecutive_id: nil,
      cache_path: nil,
      computed_digest: nil
    }
  end

  defp tarball(id, original, options) do
    name = id |> URI.parse() |> Map.get(:path) |> Kernel.||("") |> Path.basename()

    case Regex.run(~r/devcontainer-feature-(.*).tgz/, name) do
      [_, feature_id] when feature_id != "" ->
        if Regex.match?(~r/^[a-zA-Z0-9_-]*$/, feature_id),
          do:
            new_set(%{type: :tarball, uri: id, user_feature_id: original}, feature_id, options, %{
              "name" => id
            }),
          else: fail("the feature #{original} has an id that isn't letters, digits, - and _")

      _ ->
        fail("the feature #{original} has to be an archive named devcontainer-feature-<id>.tgz")
    end
  end

  # A feature in the repo, which has to be in its .devcontainer folder (the
  # devcontainer CLI's rule) or another the caller names.
  defp local(id, original, options, state) do
    workspace = Path.expand(state.opts[:workspace])

    if Path.type(id) == :absolute,
      do:
        fail(
          "the feature #{original} is an absolute path; a local feature is relative to the devcontainer.json"
        )

    folder = state.opts[:config_path] |> Path.dirname() |> Path.join(id) |> Path.expand()
    roots = [".devcontainer" | state.opts[:local_roots] || []]

    unless Enum.any?(roots, &SafeFS.inside?(folder, Path.expand(&1, workspace))),
      do: fail("the feature #{original} has to be in the repo's .devcontainer folder")

    case SafeFS.resolve(workspace, Path.relative_to(folder, workspace)) do
      {:ok, resolved} ->
        new_set(
          %{type: :file_path, resolved_path: resolved, user_feature_id: original},
          Path.basename(id),
          options,
          %{"name" => id}
        )

      {:error, :enoent} ->
        fail("the feature #{original} has no #{@feature_file}")

      {:error, _} ->
        fail("the feature #{original} leads out of the repo")
    end
  end

  defp oci(id, original, options, state) do
    with {:ok, ref} <- Ref.parse(id),
         pinned = get_in(state.lockfile, ["features", id, "integrity"]),
         {:ok, %{manifest: manifest, digest: digest}} <- manifest(state, ref, pinned) do
      new_set(
        %{
          type: :oci,
          ref: ref,
          manifest: manifest,
          manifest_digest: digest,
          user_feature_id: original,
          user_feature_id_without_version: without_version(original)
        },
        ref.id,
        options
      )
    else
      {:error, message} when is_binary(message) ->
        fail("couldn't get the feature #{original}: #{message}")

      _ ->
        fail(
          "couldn't find the feature #{original}. It may not exist, or this environment may not have access to it"
        )
    end
  end

  # One feature is looked up several times over (as a dependency, then for
  # itself); the registry is asked once.
  defp manifest(state, ref, pinned) do
    key = {__MODULE__, :manifest, state.opts[:registry].tokens, ref, pinned}

    case Process.get(key) do
      nil ->
        result = Registry.manifest(state.opts[:registry], ref, pinned)
        Process.put(key, result)
        result

      result ->
        result
    end
  end

  defp without_version(id), do: Regex.replace(~r/[:@][^\/]*$/, id, "")

  # What a feature says about itself before its files are in the build
  # folder: enough to know what it depends on.
  defp early_metadata(%{source: %{type: :oci} = source} = set, state) do
    case source.manifest["annotations"]["dev.containers.metadata"] do
      annotation when is_binary(annotation) ->
        decode(annotation, set)

      _ ->
        # Published before manifests carried it; the file is in the layer.
        scratch = scratch(state)

        try do
          unpack_oci(set, scratch, state)
          read_feature_file(scratch, set)
        after
          remove(scratch)
        end
    end
  end

  defp early_metadata(%{source: %{type: :file_path, resolved_path: path}} = set, _state) do
    case SafeFS.read(path, @feature_file, max_bytes: @max_feature_file) do
      {:ok, content} -> decode(content, set)
      {:error, _} -> fail("the feature #{set.source.user_feature_id} has no #{@feature_file}")
    end
  end

  defp early_metadata(%{source: %{type: :tarball}} = set, state) do
    scratch = scratch(state)

    try do
      unpack_tarball(set, scratch, state)
      read_feature_file(scratch, set)
    after
      remove(scratch)
    end
  end

  defp scratch(state) do
    path = Path.join(state.dst, ".scratch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  # -- fetching ------------------------------------------------------------

  defp fetch(sets, state) do
    File.mkdir_p!(state.dst)

    sets =
      sets
      |> Enum.with_index()
      |> Enum.map(fn {set, index} ->
        consecutive_id = "#{set.id}_#{index}"
        path = Path.join(state.dst, consecutive_id)
        remove(path)
        File.mkdir_p!(path)
        in_time!(state, set.source.user_feature_id)
        state.log.("Fetching the feature #{set.source.user_feature_id}")

        set = unpack(set, path, state)
        content = feature_file_content(path, set)

        %{
          set
          | consecutive_id: consecutive_id,
            cache_path: path,
            # What the feature said of itself before stands over its file.
            metadata: Map.merge(decode(content, set), set.metadata),
            order: %{
              "options" => Jsonc.key_order(content, ["options"]),
              "containerEnv" => Jsonc.key_order(content, ["containerEnv"])
            }
        }
      end)

    {:ok, sets}
  end

  defp unpack(%{source: %{type: :oci} = source} = set, path, state) do
    unpack_oci(set, path, state)
    %{set | computed_digest: source.manifest_digest}
  end

  defp unpack(%{source: %{type: :file_path, resolved_path: from}} = set, path, _state) do
    copy_tree(from, path)
    set
  end

  defp unpack(%{source: %{type: :tarball}} = set, path, state) do
    %{set | computed_digest: unpack_tarball(set, path, state)}
  end

  defp unpack_oci(%{source: %{ref: ref, manifest: manifest}} = set, path, state) do
    with [%{"digest" => digest} | _] <- manifest["layers"],
         {:ok, layer} <- Registry.blob(state.opts[:registry], ref, digest) do
      extract(layer, path, :registry, set, state)
    else
      {:error, message} ->
        fail("couldn't download the feature #{set.source.user_feature_id}: #{message}")

      _ ->
        fail("the feature #{set.source.user_feature_id} has no files")
    end
  end

  defp unpack_tarball(%{source: %{uri: uri, user_feature_id: id}} = set, path, state) do
    fetch_url = state.opts[:fetch_url] || (&download(&1, &2, state.opts[:deadline]))

    case fetch_url.(uri, request_headers(uri, state.opts[:github_token])) do
      {:ok, archive} ->
        # It may have arrived, but not in time.
        in_time!(state, id)

        digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, archive), case: :lower)
        expected = get_in(state.lockfile, ["features", uri, "integrity"])

        if expected && expected != digest,
          do: fail("the feature #{id} isn't what the lock file says it is")

        extract(archive, path, :url, set, state)
        digest

      {:error, message} ->
        fail("couldn't download the feature #{id}: #{message}")
    end
  end

  # A GitHub token goes to GitHub (a release asset of a private repo), and
  # to no host that only starts with its name.
  defp request_headers(url, token) do
    host = URI.parse(url).host

    [{"user-agent", "devcontainer"}] ++
      if(is_binary(token) and host in ["github.com", "api.github.com"],
        do: [{"authorization", "Bearer #{token}"}],
        else: []
      )
  end

  # Kept as it arrives, and given up on past the size limit.
  defp download(url, headers, deadline) do
    left = fn -> if deadline, do: deadline - System.monotonic_time(:millisecond), else: 60_000 end

    collect = fn {:data, data}, {request, response} ->
      size = Map.get(response.private, :size, 0) + byte_size(data)

      if size > @max_archive or left.() <= 0 do
        {:halt, {request, Req.Response.put_private(response, :too_large, size > @max_archive)}}
      else
        response =
          response
          |> Req.Response.put_private(:size, size)
          |> Req.Response.put_private(:chunks, [data | Map.get(response.private, :chunks, [])])

        {:cont, {request, response}}
      end
    end

    request =
      Req.new(
        url: url,
        headers: headers,
        retry: false,
        decode_body: false,
        compressed: false,
        receive_timeout: left.() |> min(60_000) |> max(1),
        into: collect
      )

    case Req.get(request) do
      {:ok, %Req.Response{private: %{too_large: true}}} ->
        {:error, "it's larger than Foreman downloads"}

      {:ok, %Req.Response{private: %{too_large: false}}} ->
        {:error, "there was no time left"}

      {:ok, %Req.Response{status: 200, private: private}} ->
        {:ok, private |> Map.get(:chunks, []) |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, %Req.Response{status: status}} ->
        {:error, "the server answered #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Unpacks a feature's archive: a tar, which may be gzipped. It's
  # unzipped here, up to a limit, so one that's far bigger than it looks
  # is given up on before it fills memory or the disk. erl_tar is held to
  # the same limit for what it writes, and refuses entries that would land
  # outside `path`, links included. The archive is never listed first:
  # listing has no such limit.
  defp extract(archive, path, from, set, state) do
    max = state.opts[:max_unpacked_bytes] || @max_archive

    result =
      with {:ok, tar} <- plain_tar(archive, format(archive), max),
           :ok <- no_sparse_files(tar) do
        :erl_tar.extract({:binary, tar}, [{:cwd, String.to_charlist(path)}, {:max_size, max}])
      end

    case result do
      :ok ->
        if from == :url, do: drop_hidden(path)
        :ok

      {:error, reason} ->
        remove(path)

        fail(
          "couldn't unpack the feature #{set.source.user_feature_id}: #{describe(reason, max)}"
        )
    end
  end

  # A sparse file says how long it is without holding that much, and
  # erl_tar's limit can be talked out of counting it: it sizes the file
  # from the member's own header, then checks the limit against a size an
  # extended header before it can restate. Features don't have sparse
  # files, so an archive with one is refused before erl_tar reads it.
  #
  # Every 512-byte block is tested for being such a header, by erl_tar's
  # own test (erl_tar.erl, get_format/1 and read_element_header/2), so
  # nothing about how the archive is framed can step this past one. A
  # feature that ships an archive holding sparse files is refused too.
  defp no_sparse_files(<<block::binary-size(512), rest::binary>>) do
    if sparse_header?(block), do: {:error, :sparse}, else: no_sparse_files(rest)
  end

  defp no_sparse_files(_end), do: :ok

  defp sparse_header?(<<before::binary-size(148), checksum::binary-size(8), ?S, rest::binary>>) do
    bytes = :binary.bin_to_list(before <> "        S" <> rest)

    case tar_octal(checksum, 0) do
      # Summed as unsigned bytes or as signed ones: unpackers take either.
      {:ok, sum} ->
        sum == Enum.sum(bytes) or
          sum == Enum.sum(Enum.map(bytes, &if(&1 > 127, do: &1 - 256, else: &1)))

      :error ->
        false
    end
  end

  defp sparse_header?(_block), do: false

  # A checksum as erl_tar reads it: octal digits, with any spaces and
  # NULs among them passed over.
  defp tar_octal(<<>>, acc), do: {:ok, acc}
  defp tar_octal(<<char, rest::binary>>, acc) when char in [?\s, 0], do: tar_octal(rest, acc)

  defp tar_octal(<<char, rest::binary>>, acc) when char in ?0..?7,
    do: tar_octal(rest, acc * 8 + char - ?0)

  defp tar_octal(_other, _acc), do: :error

  # An archive from a URL leaves its top-level dotfiles behind, and an
  # older format's archive of archives.
  defp drop_hidden(path) do
    for name <- File.ls!(path),
        String.starts_with?(name, ".") or name == "devcontainer-features.tgz" do
      remove(Path.join(path, name))
    end
  end

  # An archive can leave folders its own modes keep the agent out of.
  defp remove(path) do
    with {:error, _, _} <- File.rm_rf(path) do
      open_up(path)
      File.rm_rf(path)
    end
  end

  defp open_up(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        File.chmod(path, 0o700)

        for name <- elem(File.ls(path), 1) |> List.wrap(),
            is_binary(name),
            do: open_up(Path.join(path, name))

      _ ->
        :ok
    end
  end

  # By what it is, not what it's called: the devcontainer CLI packages
  # plain tar under a .tgz name.
  defp format(<<0x1F, 0x8B, _::binary>>), do: :gzip
  defp format(_archive), do: :tar

  defp plain_tar(archive, :tar, max),
    do: if(byte_size(archive) > max, do: {:error, :too_large}, else: {:ok, archive})

  defp plain_tar(archive, :gzip, max) do
    z = :zlib.open()

    try do
      # 16 + 15: gzip. An archive can be several gzip streams end to end.
      :ok = :zlib.inflateInit(z, 31, :reset)

      with {:ok, tar} <- inflate(z, :zlib.safeInflate(z, archive), [], 0, max) do
        # Raises unless the last stream ended where the data did.
        :zlib.inflateEnd(z)
        {:ok, tar}
      end
    rescue
      ErlangError -> {:error, :not_gzip}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {more, output}, acc, size, max) do
    size = size + IO.iodata_length(output)

    cond do
      size > max -> {:error, :too_large}
      more == :continue -> inflate(z, :zlib.safeInflate(z, []), [acc | output], size, max)
      true -> {:ok, IO.iodata_to_binary([acc | output])}
    end
  end

  defp describe(:too_large, max), do: "it's larger than Foreman unpacks (#{max} bytes)"
  defp describe(:not_gzip, _max), do: "it isn't a whole gzipped archive"
  defp describe(:too_big, max), do: describe(:too_large, max)
  defp describe(:sparse, _max), do: "it has a sparse file, which Foreman doesn't unpack"
  defp describe({:max_size_exceeded, _}, max), do: describe(:too_large, max)
  defp describe(:max_size_exceeded, max), do: describe(:too_large, max)
  defp describe({name, reason}, _max) when is_list(name), do: "#{name}: #{reason}"
  defp describe(reason, _max), do: inspect(reason)

  # Copies a folder as it is: a link stays a link, so nothing outside the
  # folder is read on the way.
  defp copy_tree(from, to) do
    File.mkdir_p!(to)

    for name <- File.ls!(from) do
      source = Path.join(from, name)
      target = Path.join(to, name)

      case File.lstat!(source) do
        %File.Stat{type: :directory} ->
          copy_tree(source, target)

        %File.Stat{type: :symlink} ->
          {:ok, link} = :file.read_link_all(source)
          File.ln_s!(IO.chardata_to_string(link), target)

        %File.Stat{type: :regular, mode: mode} ->
          copy_file(source, target, mode)

        _ ->
          :ok
      end
    end

    :ok
  end

  # In this process, a piece at a time: a copy by name is done by a file
  # server every process shares, which finishes it whether or not the
  # one that asked is still there to want it.
  defp copy_file(source, target, mode) do
    source |> File.stream!(65_536) |> Stream.into(File.stream!(target)) |> Stream.run()
    File.chmod!(target, Bitwise.band(mode, 0o777))
  end

  defp read_feature_file(path, set), do: decode(feature_file_content(path, set), set)

  defp feature_file_content(path, set) do
    case SafeFS.read(path, @feature_file, max_bytes: @max_feature_file) do
      {:ok, content} -> content
      {:error, _} -> fail("the feature #{set.source.user_feature_id} has no #{@feature_file}")
    end
  end

  defp decode(content, set) do
    case Jsonc.decode(content) do
      {:ok, metadata} ->
        metadata

      {:error, "invalid JSON" <> _ = message} ->
        fail("the feature #{set.source.user_feature_id}'s #{@feature_file}: #{message}")

      {:error, _} ->
        fail(
          "the feature #{set.source.user_feature_id}'s #{@feature_file}: invalid JSON, it must be an object"
        )
    end
  end

  # -- lock file -----------------------------------------------------------

  @doc """
  The content of the `devcontainer-lock.json` for what was installed: each
  of the config's own features that came from a registry or a URL, and
  what those depend on, with the digest that was pulled.
  """
  @spec lockfile([set()], map(), map()) :: String.t()
  def lockfile(sets, config, additional) do
    declared = Map.keys(if is_map(config["features"]), do: config["features"], else: %{})
    excluded = Map.keys(additional || %{}) -- declared

    entries =
      for %{source: %{type: type} = source} = set <- sets,
          type in [:oci, :tarball],
          source.user_feature_id not in excluded do
        resolved =
          case source do
            %{type: :oci, ref: ref} -> "#{ref.registry}/#{ref.path}@#{set.computed_digest}"
            %{uri: uri} -> uri
          end

        depends_on = set.metadata["dependsOn"] |> object() |> Map.keys()

        fields =
          [
            {"version", JSON.encode!(set.metadata["version"])},
            {"resolved", JSON.encode!(resolved)},
            {"integrity", JSON.encode!(set.computed_digest)}
          ] ++
            if depends_on == [],
              do: [],
              else: [
                {"dependsOn",
                 "[\n" <>
                   Enum.map_join(depends_on, ",\n", &("        " <> JSON.encode!(&1))) <>
                   "\n      ]"}
              ]

        {source.user_feature_id, fields}
      end

    case Enum.sort(entries, fn {a, _}, {b, _} -> Order.collate(a, b) != :gt end) do
      [] ->
        "{\n  \"features\": {}\n}\n"

      entries ->
        body =
          Enum.map_join(entries, ",\n", fn {id, fields} ->
            "    #{JSON.encode!(id)}: {\n" <>
              Enum.map_join(fields, ",\n", fn {key, value} ->
                "      #{JSON.encode!(key)}: #{value}"
              end) <>
              "\n    }"
          end)

        "{\n  \"features\": {\n" <> body <> "\n  }\n}\n"
    end
  end

  defp object(value) when is_map(value), do: value
  defp object(_value), do: %{}

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(_value), do: []

  @spec fail(String.t()) :: no_return()
  defp fail(message), do: throw({:feature_error, message})
end
