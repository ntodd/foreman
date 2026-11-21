defmodule ForemanAgent.Devcontainer.Features.Order do
  @moduledoc """
  The order features install in, as the devcontainer spec has it: in
  rounds. A round is every feature whose dependencies (`dependsOn`, and
  the `installsAfter` ones that are being installed at all) went in an
  earlier round; of those, the ones with the highest priority
  (`overrideFeatureInstallOrder`) go, sorted. The sort is the devcontainer
  CLI's, so the same features install in the same order and number, and
  an image either built reuses the other's layers.

  A node is a feature in the graph:

      %{
        user_feature_id: "ghcr.io/o/features/a:1",
        options: true | "1" | %{...},
        set: %{source: %{type: :oci | :file_path | :tarball, ...}},
        depends_on: [node],        # hard: this feature with these options
        installs_after: [node],    # soft: this feature at any version
        aliases: [id] | nil,       # the feature's current id and former ones
        priority: 0
      }
  """

  @type feature_node :: map()

  @doc """
  The nodes in install order. `:circular` with the ids left over when the
  rest wait on each other, or on something that isn't being installed.
  """
  @spec install_order([feature_node()]) ::
          {:ok, [feature_node()]} | {:error, :circular, [String.t()]}
  def install_order(worklist) do
    worklist
    |> Enum.map(fn node ->
      # A soft dependency on a feature that isn't being installed is no dependency.
      relevant =
        Enum.filter(node.installs_after, fn soft ->
          Enum.any?(worklist, &satisfies_soft?(&1, soft))
        end)

      %{node | installs_after: relevant}
    end)
    |> rounds([])
  end

  defp rounds([], installed), do: {:ok, installed}

  defp rounds(worklist, installed) do
    ready =
      Enum.filter(worklist, fn node ->
        Enum.all?(node.depends_on, fn dep -> Enum.any?(installed, &equal?(&1, dep)) end) and
          Enum.all?(node.installs_after, fn soft ->
            Enum.any?(installed, &satisfies_soft?(&1, soft))
          end)
      end)

    case ready do
      [] ->
        {:error, :circular, Enum.map(worklist, & &1.user_feature_id)}

      ready ->
        highest = ready |> Enum.map(& &1.priority) |> Enum.max()
        round = Enum.filter(ready, &(&1.priority == highest))
        rest = Enum.reject(worklist, fn node -> Enum.any?(round, &equal?(&1, node)) end)
        rounds(rest, installed ++ Enum.sort(round, &(compare(&1, &2) != :gt)))
    end
  end

  @doc """
  The worklist with `overrideFeatureInstallOrder` applied: a feature an
  override names gets a priority, higher the earlier it's named.
  """
  @spec prioritize([feature_node()], [feature_node()]) :: [feature_node()]
  def prioritize(worklist, overrides) do
    count = length(overrides)

    overrides
    |> Enum.with_index()
    |> Enum.reduce(worklist, fn {override, index}, worklist ->
      Enum.map(worklist, fn node ->
        if satisfies_soft?(node, override),
          do: %{node | priority: max(node.priority, count - index)},
          else: node
      end)
    end)
  end

  @doc "Whether two nodes are the same feature with the same options."
  @spec equal?(feature_node(), feature_node()) :: boolean()
  def equal?(a, b), do: a.set.source.type == b.set.source.type and compare(a, b) == :eq

  @doc "Whether `node` is the feature the soft dependency `soft` names, at any version."
  @spec satisfies_soft?(feature_node(), feature_node()) :: boolean()
  def satisfies_soft?(
        %{set: %{source: %{type: type} = source}},
        %{set: %{source: %{type: type} = soft}} = dep
      ) do
    case type do
      :oci ->
        prefix = soft.ref.registry <> "/" <> soft.ref.namespace

        source.ref.resource == soft.ref.resource or
          Enum.any?(dep[:aliases] || [], &(prefix <> "/" <> &1 == source.ref.resource))

      :file_path ->
        source.resolved_path == soft.resolved_path

      :tarball ->
        source.uri == soft.uri
    end
  end

  def satisfies_soft?(_node, _soft), do: false

  @spec compare(feature_node(), feature_node()) :: :lt | :eq | :gt
  def compare(
        %{set: %{source: %{type: type} = a}} = node_a,
        %{set: %{source: %{type: type} = b}} = node_b
      ) do
    case type do
      :oci ->
        if a.manifest_digest == b.manifest_digest and
             options(node_a.options, node_b.options) == :eq do
          :eq
        else
          first_difference([
            fn -> resource(a.ref, node_a[:aliases], b.ref, node_b[:aliases]) end,
            fn -> if a.ref.tag && b.ref.tag, do: collate(a.ref.tag, b.ref.tag), else: :eq end,
            fn -> options(node_a.options, node_b.options) end,
            fn -> collate(a.manifest_digest, b.manifest_digest) end
          ])
        end

      :file_path ->
        first_difference([
          fn -> collate(a.resolved_path, b.resolved_path) end,
          fn -> options(node_a.options, node_b.options) end
        ])

      :tarball ->
        first_difference([
          fn -> collate(a.uri, b.uri) end,
          fn -> options(node_a.options, node_b.options) end
        ])
    end
  end

  def compare(a, b), do: collate(a.set.source.user_feature_id, b.set.source.user_feature_id)

  defp first_difference(comparisons) do
    Enum.find_value(comparisons, :eq, fn comparison ->
      case comparison.() do
        :eq -> nil
        other -> other
      end
    end)
  end

  # By registry and namespace, then by id unless the two share one (a
  # renamed feature is the same feature under either name).
  defp resource(a, a_aliases, b, b_aliases) do
    a_prefix = a.registry <> "/" <> a.namespace
    b_prefix = b.registry <> "/" <> b.namespace

    cond do
      a_prefix != b_prefix -> collate(a_prefix, b_prefix)
      Enum.any?(a_aliases || [a.id], &(&1 in (b_aliases || [b.id]))) -> :eq
      true -> collate(a.id, b.id)
    end
  end

  defp options(a, b) when is_binary(a) and is_binary(b), do: collate(a, b)
  defp options(a, b) when is_boolean(a) and is_boolean(b), do: boolean(a, b)

  defp options(a, b) when is_map(a) and is_map(b) do
    a_keys = a |> Map.keys() |> Enum.sort()
    b_keys = b |> Map.keys() |> Enum.sort()

    cond do
      length(a_keys) < length(b_keys) ->
        :lt

      length(a_keys) > length(b_keys) ->
        :gt

      true ->
        a_keys
        |> Enum.zip(b_keys)
        |> Enum.find_value(:eq, fn {a_key, b_key} ->
          if a_key != b_key, do: collate(a_key, b_key), else: differs(value(a[a_key], b[b_key]))
        end)
    end
  end

  defp options(a, b), do: collate(kind(a), kind(b))

  defp value(a, b) when is_binary(a) and is_binary(b), do: collate(a, b)
  defp value(a, b) when is_boolean(a) and is_boolean(b), do: boolean(a, b)
  defp value(nil, nil), do: :eq
  defp value(nil, _b), do: :gt
  defp value(_a, nil), do: :lt
  # Values of different kinds aren't compared.
  defp value(_a, _b), do: :eq

  defp differs(:eq), do: nil
  defp differs(other), do: other

  defp boolean(a, a), do: :eq
  defp boolean(true, false), do: :gt
  defp boolean(false, true), do: :lt

  defp kind(value) when is_binary(value), do: "string"
  defp kind(value) when is_boolean(value), do: "boolean"
  defp kind(value) when is_number(value), do: "number"
  defp kind(_value), do: "object"

  # JavaScript's localeCompare, for the characters feature ids, tags, paths
  # and URLs are made of: punctuation, then digits, then letters; a letter's
  # case only breaks a tie, lowercase first.
  @punctuation ~c" _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$"
  @weights @punctuation |> Enum.with_index(1) |> Map.new()

  @doc "How two strings order, as `:lt`, `:eq` or `:gt`."
  @spec collate(String.t(), String.t()) :: :lt | :eq | :gt
  def collate(a, b) do
    a_chars = String.to_charlist(a)
    b_chars = String.to_charlist(b)

    case order(Enum.map(a_chars, &weight/1), Enum.map(b_chars, &weight/1)) do
      :eq -> order(Enum.map(a_chars, &upper/1), Enum.map(b_chars, &upper/1))
      other -> other
    end
  end

  defp order(a, a), do: :eq
  defp order(a, b) when a < b, do: :lt
  defp order(_a, _b), do: :gt

  defp weight(char) when char in ?0..?9, do: 100 + char - ?0
  defp weight(char) when char in ?a..?z, do: 200 + char - ?a
  defp weight(char) when char in ?A..?Z, do: 200 + char - ?A
  defp weight(char), do: Map.get(@weights, char, 1000 + char)

  defp upper(char) when char in ?A..?Z, do: 1
  defp upper(_char), do: 0
end
