defmodule ForemanAgent.Devcontainer.Metadata do
  @moduledoc """
  Image metadata: the `devcontainer.metadata` label a devcontainer's image
  and container carry, which is a list of entries, oldest first. The base
  image's come first, then one for each feature installed, then the
  devcontainer.json's own. Merged, they are how the container is run:
  the config, with what the image and its features add.

  Entries are as they're written, with their `${...}` variables in
  place; whoever merges them substitutes first.
  """

  @label "devcontainer.metadata"

  @hooks ~w(onCreateCommand updateContentCommand postCreateCommand postStartCommand postAttachCommand)

  # What a devcontainer.json contributes, in the order the devcontainer CLI
  # writes it.
  @config_properties @hooks ++
                       ~w(waitFor customizations mounts containerEnv containerUser init
                          privileged capAdd securityOpt remoteUser userEnvProbe remoteEnv
                          overrideCommand portsAttributes otherPortsAttributes forwardPorts
                          shutdownAction updateRemoteUserUID hostRequirements)

  # What can change on a container that exists: nothing it was created with.
  @updateable_properties ~w(remoteUser userEnvProbe remoteEnv)

  @feature_properties @hooks ++
                        ~w(init privileged capAdd securityOpt entrypoint mounts customizations)

  # A merged config has these as lists (`entrypoints`, `postCreateCommands`), or not at all.
  @replaced ~w(customizations entrypoint shutdownAction) ++ @hooks

  @type entry :: %{String.t() => term()}

  def label_name, do: @label
  def hooks, do: @hooks

  @doc "The entries in an image's or a container's labels."
  @spec from_labels(map() | nil) :: [entry()]
  def from_labels(labels) do
    with value when is_binary(value) <- (labels || %{})[@label],
         {:ok, decoded} <- JSON.decode(value) do
      case decoded do
        list when is_list(list) -> Enum.filter(list, &is_map/1)
        %{} = entry -> [entry]
        _ -> []
      end
    else
      _ -> []
    end
  end

  @doc """
  The entries of an image built from `base` (its base image's entries)
  with `feature_sets` installed, for the devcontainer.json `config`.
  """
  @spec build([entry()], [map()], map()) :: [entry()]
  def build(base, feature_sets, config) do
    features =
      for set <- feature_sets do
        set.metadata
        |> old_feature_properties()
        |> Map.take(@feature_properties)
        |> Map.put("id", set.source.user_feature_id)
      end

    Enum.reject(base ++ features ++ [Map.take(config, @config_properties)], &(&1 == %{}))
  end

  @doc """
  The entries of a container that exists. One the id labels are on was
  made for this config, so its label is the whole story, less what a
  config can change afterwards.
  """
  @spec from_container(map(), map(), [String.t()]) :: [entry()]
  def from_container(container, config, id_labels) do
    labels = get_in(container, ["Config", "Labels"]) || %{}

    cond do
      not is_binary(labels[@label]) ->
        build([], [], config)

      id_labels != [] and Enum.all?(id_labels, &has_label?(labels, &1)) ->
        Enum.reject(
          from_labels(labels) ++ [Map.take(config, @updateable_properties)],
          &(&1 == %{})
        )

      true ->
        build(from_labels(labels), [], config)
    end
  end

  defp has_label?(labels, id_label) do
    case String.split(id_label, "=", parts: 2) do
      [name, _value] -> labels[name] not in [nil, ""]
      _ -> true
    end
  end

  @doc "The Dockerfile instruction that puts the entries on an image."
  @spec label([entry()]) :: String.t()
  def label([]), do: ""

  def label(entries) do
    lines = Enum.map_join(entries, ",", &(" \\\n" <> escape(encode(&1))))
    ~s(LABEL #{@label}="[#{lines} \\\n]")
  end

  @doc "The entries as a container label's value."
  @spec label_value([entry()]) :: String.t()
  def label_value(entries), do: "[" <> Enum.map_join(entries, ",", &encode/1) <> "]"

  defp escape(json), do: String.replace(json, ~r/(?=["\\$])/, "\\")

  # Keys in the order the devcontainer CLI writes them, so an image built
  # by either has the same label, and a build can reuse the other's layers.
  defp encode(entry) do
    order =
      if Map.has_key?(entry, "id"), do: ["id" | @feature_properties], else: @config_properties

    known = for key <- order, Map.has_key?(entry, key), do: key
    rest = entry |> Map.keys() |> Kernel.--(known) |> Enum.sort()

    "{" <>
      Enum.map_join(known ++ rest, ",", &(JSON.encode!(&1) <> ":" <> JSON.encode!(entry[&1]))) <>
      "}"
  end

  @doc """
  The config as the container runs with it: `config`, with what all the
  entries say merged in. Lifecycle commands and entrypoints become lists
  (`postCreateCommands`, `entrypoints`), one from each entry that has one.
  """
  @spec merge(map(), [entry()]) :: map()
  def merge(config, entries) do
    reversed = Enum.reverse(entries)
    last = fn key -> Enum.find_value(reversed, & &1[key]) end

    last_boolean = fn key ->
      Enum.find_value(reversed, fn e -> if is_boolean(e[key]), do: {e[key]} end)
    end

    config
    |> Map.drop(@replaced)
    |> Map.merge(%{
      "init" => Enum.any?(entries, &truthy?(&1["init"])),
      "privileged" => Enum.any?(entries, &truthy?(&1["privileged"])),
      "capAdd" => union(entries, "capAdd"),
      "securityOpt" => union(entries, "securityOpt"),
      "entrypoints" =>
        entries |> Enum.map(& &1["entrypoint"]) |> Enum.filter(&truthy?/1) |> none_as_nil(),
      "mounts" => merge_mounts(entries),
      "waitFor" => last.("waitFor"),
      "remoteUser" => last.("remoteUser"),
      "containerUser" => last.("containerUser"),
      "userEnvProbe" => last.("userEnvProbe"),
      "remoteEnv" => merge_maps(entries, "remoteEnv"),
      "containerEnv" => merge_maps(entries, "containerEnv"),
      "overrideCommand" => unwrap(last_boolean.("overrideCommand")),
      "updateRemoteUserUID" => unwrap(last_boolean.("updateRemoteUserUID"))
    })
    |> Map.merge(Map.new(@hooks, &{&1 <> "s", commands(entries, &1)}))
  end

  defp unwrap({value}), do: value
  defp unwrap(nil), do: nil

  defp truthy?(value), do: value not in [nil, false, "", 0]

  defp none_as_nil([]), do: nil
  defp none_as_nil(list), do: list

  defp union(entries, key) do
    entries
    |> Enum.flat_map(&List.wrap(if is_list(&1[key]), do: &1[key]))
    |> Enum.uniq()
    |> none_as_nil()
  end

  defp merge_maps(entries, key) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      if is_map(entry[key]), do: Map.merge(acc, entry[key]), else: acc
    end)
  end

  defp commands(entries, hook), do: entries |> Enum.map(& &1[hook]) |> Enum.filter(&truthy?/1)

  # A later mount of a target replaces an earlier one.
  defp merge_mounts(entries) do
    entries
    |> Enum.flat_map(&List.wrap(if is_list(&1["mounts"]), do: &1["mounts"]))
    |> Enum.reverse()
    |> Enum.uniq_by(&parse_mount(&1)["target"])
    |> Enum.reverse()
    |> none_as_nil()
  end

  @mount_keys %{"src" => "source", "destination" => "target", "dst" => "target"}

  @doc "A mount as a map, from the `type=...,source=...,target=...` form or as it is."
  @spec parse_mount(String.t() | map()) :: map()
  def parse_mount(mount) when is_map(mount), do: mount

  def parse_mount(mount) when is_binary(mount) do
    for part <- String.split(mount, ","), into: %{} do
      case String.split(part, "=", parts: 2) do
        [key, value] -> {Map.get(@mount_keys, key, key), value}
        [key] -> {Map.get(@mount_keys, key, key), nil}
      end
    end
  end

  @doc """
  Each lifecycle hook's commands, in the order they run, with where each
  came from: a feature's id, or `devcontainer.json`.
  """
  @spec lifecycle_origins([entry()]) :: %{String.t() => [{String.t(), term()}]}
  def lifecycle_origins(entries) do
    Map.new(@hooks, fn hook ->
      {hook,
       for(
         entry <- entries,
         truthy?(entry[hook]),
         do: {entry["id"] || "devcontainer.json", entry[hook]}
       )}
    end)
  end

  # Features once listed VS Code's extensions and settings at the top.
  defp old_feature_properties(%{} = feature) do
    if Map.has_key?(feature, "extensions") or Map.has_key?(feature, "settings") do
      customizations =
        if is_map(feature["customizations"]), do: feature["customizations"], else: %{}

      vscode = if is_map(customizations["vscode"]), do: customizations["vscode"], else: %{}

      vscode =
        vscode
        |> then(fn v ->
          if is_list(feature["extensions"]),
            do: Map.put(v, "extensions", List.wrap(v["extensions"]) ++ feature["extensions"]),
            else: v
        end)
        |> then(fn v ->
          if is_map(feature["settings"]),
            do: Map.put(v, "settings", Map.merge(feature["settings"], v["settings"] || %{})),
            else: v
        end)

      feature
      |> Map.drop(["extensions", "settings"])
      |> Map.put("customizations", Map.put(customizations, "vscode", vscode))
    else
      feature
    end
  end
end
