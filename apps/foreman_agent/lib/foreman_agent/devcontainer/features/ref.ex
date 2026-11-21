defmodule ForemanAgent.Devcontainer.Features.Ref do
  @moduledoc """
  A feature's place in an OCI registry, parsed from how a devcontainer.json
  names it: `ghcr.io/devcontainers/features/go:1`, or with a digest
  (`...@sha256:...`). No version means `latest`.
  """

  @enforce_keys [:scheme, :registry, :owner, :namespace, :path, :resource, :id, :version]
  defstruct [
    :scheme,
    :registry,
    :owner,
    :namespace,
    :path,
    :resource,
    :id,
    :version,
    :tag,
    :digest
  ]

  @type t :: %__MODULE__{
          scheme: String.t(),
          registry: String.t(),
          owner: String.t(),
          namespace: String.t(),
          path: String.t(),
          resource: String.t(),
          id: String.t(),
          version: String.t(),
          tag: String.t() | nil,
          digest: String.t() | nil
        }

  # The repository, as the distribution spec has it.
  @path ~r/^[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*$/
  @tag ~r/^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$/

  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(input) when is_binary(input) do
    input = String.downcase(input)

    with false <- String.starts_with?(input, "."),
         {:ok, resource, tag, digest} <- version(input),
         true <- is_nil(tag) or Regex.match?(@tag, tag),
         [registry, owner | _] = parts <- relocated(String.split(resource, "/")),
         id = List.last(parts),
         namespace = parts |> Enum.slice(1..-2//1) |> Enum.join("/"),
         path = namespace <> "/" <> id,
         true <- Regex.match?(@path, path) do
      {:ok,
       %__MODULE__{
         scheme: scheme(registry),
         registry: registry,
         owner: owner,
         namespace: namespace,
         path: path,
         resource: resource,
         id: id,
         version: digest || tag || "latest",
         tag: tag,
         digest: digest
       }}
    else
      _ -> :error
    end
  end

  defp version(input) do
    case last_index(input, "@") do
      nil ->
        {resource, tag} = tagged(input)
        {:ok, resource, tag || "latest", nil}

      at ->
        {resource, tag} = tagged(binary_part(input, 0, at))
        digest = rest(input, at)

        case String.split(digest, ":") do
          ["sha256", _hash] -> {:ok, resource, tag, digest}
          _ -> :error
        end
    end
  end

  # A ref and its tag, if it has one. A colon before the last slash is the
  # registry's port.
  defp tagged(ref) do
    colon = last_index(ref, ":")

    if colon && colon > (last_index(ref, "/") || -1),
      do: {binary_part(ref, 0, colon), rest(ref, colon)},
      else: {ref, nil}
  end

  # devcontainers-contrib moved; its features are published under the new name.
  defp relocated([registry, "devcontainers-contrib" | rest]),
    do: [registry, "devcontainers-extra" | rest]

  defp relocated(parts), do: parts

  defp scheme(registry) do
    case String.split(registry, ":") do
      ["localhost" | _] -> "http"
      _ -> "https"
    end
  end

  defp last_index(string, char) do
    case :binary.matches(string, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp rest(string, index), do: binary_part(string, index + 1, byte_size(string) - index - 1)
end
