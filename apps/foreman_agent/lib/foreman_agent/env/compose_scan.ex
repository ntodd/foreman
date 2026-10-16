defmodule ForemanAgent.Env.ComposeScan do
  @moduledoc """
  Reads a repo's compose files the way compose will, before compose does.

  Compose reads some files while it parses: env files and label files
  (into services' environments and labels), included compose files and
  their env files, and the files services extend. By the time
  `docker compose config` shows a config it has read them all, folded
  their values in where the path can't be seen, and quoted any it
  couldn't parse in its error. So the agent reads the repo's files first,
  as written, and lists what compose would read and which keys it would
  meet; `ForemanAgent.Env.Policy.check_sources/2` decides.

  Included and extended files inside the clone are read in turn; one
  outside it is reported, never read. Merge keys (`<<`) are kept rather
  than merged, and every value a service could end up with is reported,
  so a different reading of a merge can't hide a path. Anything this
  can't read the way compose would (an unknown YAML tag, aliases that
  expand without end, too many files) is an error, never a pass.
  """

  alias ForemanAgent.Env.Policy
  alias ForemanAgent.SafeFS

  @max_files 50
  @max_bytes 1_048_576

  @type fact ::
          {:file, String.t(), String.t()}
          | {:key, String.t(), String.t()}
          | {:provider, String.t()}
          | {:api_socket, String.t()}

  @doc """
  Scans `compose_files` (absolute paths inside `clone`, as the devcontainer
  lists them) and whatever they include or extend.
  """
  @spec scan(Path.t(), [Path.t()]) :: {:ok, [fact()]} | {:error, String.t()}
  def scan(clone, [first | _] = compose_files) do
    clone = Path.expand(clone)
    project_dir = Path.dirname(first)
    queue = Enum.map(compose_files, &{&1, project_dir})

    case walk(queue, %{clone: clone, seen: MapSet.new(), facts: []}) do
      {:ok, state} -> {:ok, state.facts |> Enum.reverse() |> Enum.uniq()}
      {:error, _} = error -> error
    end
  end

  defp walk([], state), do: {:ok, state}

  defp walk([{path, base} | rest], state) do
    cond do
      MapSet.member?(state.seen, path) ->
        walk(rest, state)

      MapSet.size(state.seen) >= @max_files ->
        {:error, "the compose files include too many others (more than #{@max_files})"}

      true ->
        state = %{state | seen: MapSet.put(state.seen, path)}

        with {:ok, doc} <- read(state.clone, path),
             {:ok, facts, more} <- document(doc, path, base, state.clone) do
          walk(rest ++ more, %{state | facts: Enum.reverse(facts, state.facts)})
        end
    end
  end

  defp read(clone, path) do
    rel = Path.relative_to(path, clone)

    with {:ok, content} <- read_file(clone, rel),
         {:ok, doc} <- parse(content, rel) do
      {:ok, doc || %{}}
    end
  end

  defp read_file(clone, rel) do
    case SafeFS.read(clone, rel, max_bytes: @max_bytes) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "#{rel} not found"}
      {:error, :too_large} -> {:error, "#{rel} is larger than #{div(@max_bytes, 1024)} KiB"}
      {:error, reason} -> {:error, "couldn't read #{rel}: #{inspect(reason)}"}
    end
  end

  # js-yaml (vendored in priv/yaml, run with the Node the devcontainer CLI
  # needs anyway): Erlang's yamerl resolves an alias to a list or map as
  # its first scalar, which would hide whatever a merge brings in. The
  # script keeps `<<` merges as keys, reads compose's own tags as plain
  # values, refuses any other tag and duplicate keys, and stops at a node
  # budget (aliases can expand without end).
  defp parse(content, rel) do
    with {:ok, node} <- find_node() do
      tmp =
        Path.join(System.tmp_dir!(), "foreman-compose-#{System.unique_integer([:positive])}.yml")

      try do
        File.write!(tmp, content)
        File.chmod!(tmp, 0o600)

        case MuonTrap.cmd(node, ["--max-old-space-size=256", script(), tmp],
               stderr_to_stdout: true,
               timeout: 15_000
             ) do
          {json, 0} -> decoded(JSON.decode(json), rel)
          {message, 2} -> {:error, "couldn't read #{rel}: #{String.trim(message)}"}
          {message, 3} -> {:error, "#{rel} is #{String.trim(message)}"}
          {_, :timeout} -> {:error, "#{rel} took too long to read"}
          {_, _} -> {:error, "couldn't read #{rel}"}
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp find_node do
    case System.find_executable("node") do
      nil -> {:error, "Node is needed to check compose files, and isn't installed on this box"}
      node -> {:ok, node}
    end
  end

  defp script, do: Application.app_dir(:foreman_agent, "priv/yaml/compose_yaml.js")

  defp decoded({:ok, doc}, _rel) when is_map(doc) or is_nil(doc), do: {:ok, doc}

  defp decoded({:ok, _}, rel),
    do: {:error, "#{rel} isn't a compose file (its top level isn't a map)"}

  defp decoded({:error, _}, rel), do: {:error, "couldn't read #{rel}"}

  # -- one file --------------------------------------------------------------

  defp document(doc, path, base, clone) do
    rel = Path.relative_to(path, clone)
    dir = Path.dirname(path)
    ctx = %{rel: rel, dir: dir, base: base, clone: clone}
    tops = candidates(doc)

    top_keys =
      for top <- tops,
          key <- Map.keys(top),
          not Policy.known_top_level_key?(key),
          do: {:key, "the top level of #{rel}", key}

    services =
      for top <- tops,
          {name, svc} <- map(top["services"]),
          fact <- service(name, svc, ctx),
          do: fact

    {include_facts, includes} = includes(tops, ctx)
    {extends_facts, extends} = extends(tops, ctx)

    {:ok, top_keys ++ services ++ include_facts ++ extends_facts, includes ++ extends}
  end

  # A map and every map merged into it with `<<`, any depth: whichever
  # value a merge ends up with, it's among these.
  defp candidates(map) when is_map(map) do
    {merged, own} = Map.pop(map, "<<")
    [own | merged |> List.wrap() |> Enum.flat_map(&candidates/1)]
  end

  defp candidates(_), do: []

  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}

  defp service(name, svc, ctx) do
    maps = candidates(svc)

    keys =
      for m <- maps, key <- Map.keys(m), fact <- key_fact(name, key), do: fact

    files =
      for m <- maps,
          {key, what} <- [{"env_file", "env_file"}, {"label_file", "label_file"}],
          path <- file_paths(m[key]),
          fact <- file_fact("service '#{name}' reads #{what}", path, [ctx.base, ctx.dir]),
          do: fact

    keys ++ files
  end

  defp key_fact(service, "provider"), do: [{:provider, service}]
  defp key_fact(service, "use_api_socket"), do: [{:api_socket, service}]

  defp key_fact(service, key) do
    if Policy.known_service_key?(key), do: [], else: [{:key, "service '#{service}'", key}]
  end

  # env_file: a path, a list of paths, or a list of {path, required}.
  defp file_paths(value) do
    for entry <- List.wrap(value),
        path = if(is_map(entry), do: entry["path"], else: entry),
        is_binary(path),
        do: path
  end

  # A relative path is resolved against each directory compose might use
  # for it (the project's, or the file's own); any of them leaving the
  # workspace is reported.
  defp file_fact(what, path, bases) do
    cond do
      String.contains?(path, "$") or remote?(path) ->
        [{:file, what, path}]

      Path.type(path) == :absolute ->
        [{:file, what, Path.expand(path)}]

      true ->
        bases |> Enum.uniq() |> Enum.map(&{:file, what, Path.expand(path, &1)})
    end
  end

  defp remote?(path), do: String.contains?(path, "://") or String.starts_with?(path, "git@")

  # -- include and extends ---------------------------------------------------

  defp includes(tops, ctx) do
    entries = for top <- tops, entry <- List.wrap(top["include"]), do: entry
    Enum.reduce(entries, {[], []}, &include(&1, ctx, &2))
  end

  defp include(entry, ctx, acc) when is_binary(entry),
    do: include(%{"path" => entry}, ctx, acc)

  defp include(%{} = entry, ctx, {facts, files}) do
    keys =
      for key <- Map.keys(entry),
          key not in ["path", "env_file", "project_directory"],
          do: {:key, "an include in #{ctx.rel}", key}

    project = entry["project_directory"]

    project_facts =
      if is_binary(project),
        do: file_fact("an include in #{ctx.rel} uses project_directory", project, [ctx.dir]),
        else: []

    base =
      if is_binary(project) and not String.contains?(project, "$"),
        do: Path.expand(project, ctx.dir)

    env_facts =
      for path <- file_paths(entry["env_file"]),
          fact <- file_fact("an include in #{ctx.rel} reads env_file", path, [ctx.dir]),
          do: fact

    {path_facts, read} =
      entry["path"]
      |> file_paths()
      |> Enum.reduce({[], []}, fn path, {pf, rd} ->
        case compose_file(path, ctx, "an include in #{ctx.rel} reads") do
          {:read, file} -> {pf, [{file, base || Path.dirname(file)} | rd]}
          {:fact, fact} -> {[fact | pf], rd}
        end
      end)

    {facts ++ keys ++ project_facts ++ env_facts ++ path_facts, files ++ Enum.reverse(read)}
  end

  defp include(entry, ctx, {facts, files}),
    do: {[{:key, "an include in #{ctx.rel}", inspect(entry)} | facts], files}

  defp extends(tops, ctx) do
    for top <- tops,
        {name, svc} <- map(top["services"]),
        m <- candidates(svc),
        %{} = ext <- [m["extends"]],
        reduce: {[], []} do
      {facts, files} ->
        keys =
          for key <- Map.keys(ext),
              key not in ["service", "file"],
              do: {:key, "service '#{name}' extends with", key}

        case ext["file"] do
          file when is_binary(file) ->
            case compose_file(file, ctx, "service '#{name}' extends") do
              {:read, path} -> {facts ++ keys, files ++ [{path, Path.dirname(path)}]}
              {:fact, fact} -> {facts ++ keys ++ [fact], files}
            end

          _ ->
            {facts ++ keys, files}
        end
    end
  end

  # An included or extended compose file: read it if it's in the clone
  # (symlinks resolved), otherwise report it.
  defp compose_file(path, ctx, what) do
    if String.contains?(path, "$") or remote?(path) do
      {:fact, {:file, what, path}}
    else
      full = Path.expand(path, ctx.dir)

      with true <- SafeFS.inside?(full, ctx.clone),
           {:ok, real} <- SafeFS.resolve(ctx.clone, Path.relative_to(full, ctx.clone)) do
        {:read, real}
      else
        _ -> {:fact, {:file, what, full}}
      end
    end
  end
end
